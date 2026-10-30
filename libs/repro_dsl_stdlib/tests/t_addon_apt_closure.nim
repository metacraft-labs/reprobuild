## Add-On Mode ``package(apt, ...)`` closures — hermetic cases.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §8.3, "How a
## closure is pinned, stored and bound", items 1-7. The real-archive half
## (a pinned Debian trixie armhf closure unpacked from real ``.deb``s) is
## ``t_addon_apt_closure_trixie_armhf.nim``; this file holds the cases that
## need exact control over the input: lock codec, resolution rules, unit
## rendering refusals, the unpacker's policy on hostile archive entries, mode
## normalisation, the union's conflict and symlink rules, the bounded
## downloader, and the host-architecture check.
##
## MOCK JUSTIFICATION. Two substitutions, both of the transport only:
##
## * The realiser takes its transport as an injected ``AptDebFetcher``. Most
##   cases inject a fetcher that copies ``.deb`` files this test builds on
##   disk. The code under test (verification against the lock, ``ar``
##   parsing, the in-process tar unpacker and its policy, the union) runs
##   unmodified against real archive bytes on the real filesystem.
## * ``downloadBounded`` is exercised against a one-thread HTTP/1.0 server in
##   this process that serves canned responses (an oversized body, a wrong
##   Content-Length, a redirect). A real archive cannot be made to misbehave
##   on demand; a local socket can, and the client code is the production
##   one.
##
## Real HTTP against a real archive is exercised by the trixie armhf test.
##
## Fixture ``.deb``s are built here byte for byte: a ustar stream written by
## ``tarEntry`` (so hostile entries — absolute names, ``..``, device nodes,
## hard links out of the tree, setuid modes — can be expressed, which no
## well-behaved ``tar`` would write) inside an ``ar`` container written by
## ``writeDeb``. The payloads are authored in this file.

import std/[algorithm, net, os, sequtils, strutils, tables, unittest]
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
# Fixture builders: a ustar writer and an ar writer
# ---------------------------------------------------------------------------

type
  TarFixtureEntry = object
    name: string
    typeflag: char      ## '0' file, '5' dir, '2' symlink, '1' hard link,
                        ## '3' char device, '6' FIFO
    mode: int
    content: string     ## file payload
    linkName: string    ## symlink target or hard-link target

proc tarEntry(name: string; typeflag = '0'; mode = 0o644; content = "";
              linkName = ""): TarFixtureEntry =
  TarFixtureEntry(name: name, typeflag: typeflag, mode: mode,
    content: content, linkName: linkName)

proc octal(v: int64; width: int): string =
  ## ``width-1`` octal digits and a NUL, as ustar writes numbers.
  result = toOct(v, width - 1) & "\0"

proc tarBytes(entries: seq[TarFixtureEntry]): string =
  ## A ustar stream (magic ``ustar\0``, version ``00``), owners 0:0 like a
  ## real Debian build, two zero blocks at the end.
  for e in entries:
    var h = newString(512)
    for i in 0 ..< 512: h[i] = '\0'
    doAssert e.name.len <= 100 and e.linkName.len <= 100
    h[0 ..< e.name.len] = e.name
    h[100 ..< 108] = octal(e.mode, 8)
    h[108 ..< 116] = octal(0, 8)
    h[116 ..< 124] = octal(0, 8)
    let size = if e.typeflag in {'0', 'x'}: e.content.len else: 0
    h[124 ..< 136] = octal(size, 12)
    h[136 ..< 148] = octal(0, 12)
    h[156] = e.typeflag
    if e.linkName.len > 0: h[157 ..< 157 + e.linkName.len] = e.linkName
    h[257 ..< 263] = "ustar\0"
    h[263 ..< 265] = "00"
    for i in 148 ..< 156: h[i] = ' '
    var sum = 0
    for c in h: sum += ord(c)
    h[148 ..< 155] = toOct(sum, 6) & "\0"
    h[155] = ' '
    result.add(h)
    if size > 0:
      result.add(e.content)
      let pad = (512 - size mod 512) mod 512
      result.add("\0".repeat(pad))
  result.add("\0".repeat(1024))

proc arMember(name, payload: string): string =
  var header = name & "/"
  header.add(" ".repeat(16 - header.len))
  header.add("0".alignLeft(12) & "0".alignLeft(6) & "0".alignLeft(6) &
    "100644".alignLeft(8) & ($payload.len).alignLeft(10) & "`\n")
  doAssert header.len == 60
  result = header & payload
  if (payload.len and 1) == 1: result.add('\n')

proc writeDeb(debPath: string; entries: seq[TarFixtureEntry]) =
  writeFile(debPath, "!<arch>\n" & arMember("debian-binary", "2.0\n") &
    arMember("data.tar", tarBytes(entries)))

type FixtureDeb = object
  name: string
  entries: seq[TarFixtureEntry]

proc fileDeb(name: string; files: seq[(string, string)];
             links: seq[(string, string)] = @[]): FixtureDeb =
  ## The common shape: regular files (with their parent directories) and
  ## symlinks, like ``dpkg-deb`` writes them.
  result.name = name
  var dirs: seq[string] = @["./"]
  proc addParents(rel: string) =
    var p = ""
    for c in rel.split('/')[0 .. ^2]:
      p = if p.len == 0: c else: p & "/" & c
      if ("./" & p & "/") notin dirs: dirs.add("./" & p & "/")
  for (rel, _) in files: addParents(rel)
  for (rel, _) in links: addParents(rel)
  for d in dirs: result.entries.add(tarEntry(d, '5', 0o755))
  for (rel, content) in files:
    result.entries.add(tarEntry("./" & rel, '0',
      (if rel.contains("/bin/"): 0o755 else: 0o644), content))
  for (rel, target) in links:
    result.entries.add(tarEntry("./" & rel, '2', 0o777, linkName = target))

proc buildDebs(root: string; specs: seq[FixtureDeb]):
    (AptClosureLock, Table[string, string]) =
  ## Build each fixture .deb under ``root/pool`` and a lock naming them.
  ## Returns the lock and a url -> local path map for the fetcher.
  var urls = initTable[string, string]()
  var lock = sampleLock()
  lock.debs = @[]
  lock.roots = @[specs[0].name]
  for s in specs:
    let rel = "pool/main/" & s.name & "_1.0_armhf.deb"
    let debPath = root / rel
    createDir(parentDir(debPath))
    writeDeb(debPath, s.entries)
    lock.debs.add(AptLockedDeb(name: s.name, version: "1.0",
      architecture: "armhf", filename: rel, size: getFileSize(debPath),
      sha256: sha256OfFile(debPath)))
    urls[lock.archive & "/" & rel] = debPath
  lock.debs.sort(proc (a, b: AptLockedDeb): int = cmp(a.name, b.name))
  (lock, urls)

proc localFetcher(urls: Table[string, string]; count: ref int):
    AptDebFetcher =
  result = proc (url: string; dest: string; expectedSize: int64) =
    inc count[]
    if url notin urls: raise newException(IOError, "404 " & url)
    copyFile(urls[url], dest)

proc realiseLocal(root: string; specs: seq[FixtureDeb];
                  hostMachine = "armv7l"): (string, AptClosureLock) =
  ## Build and realise a closure of ``specs`` into ``root/store``.
  let (lock, urls) = buildDebs(root, specs)
  var count = new int
  let prefix = realiseAptClosure(lock, root / "store", root / "cache",
    localFetcher(urls, count), hostMachine = hostMachine)
  (prefix, lock)

proc modeOf(path: string): int =
  when defined(posix):
    var st: Stat
    doAssert lstat(path.cstring, st) == 0, path
    int(st.st_mode.cint and 0o7777)
  else:
    0

proc storeIsClean(store: string) =
  ## Nothing but complete prefixes under the store.
  if not dirExists(store / "prefixes"): return
  for kind, p in walkDir(store / "prefixes"):
    check not p.extractFilename.startsWith(".tmp-")
    for kind2, q in walkDir(p):
      check fileExists(q / ".repro-apt-deb") or
        fileExists(q / ".repro-apt-closure")

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
    # The rendered unit passes the broker's check; the input does not.
    checkUnitForAptClosure(rendered, prefix, rendered = true)
    expect EAptClosureUnit:
      checkUnitForAptClosure(Unit, prefix, rendered = true)

  test "a wrapper, a missing [Service], a /usr bind or a new root is refused":
    let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot, sampleLock())
    for bad in [
        Unit.replace("ExecStart=/usr/bin/",
          "ExecStart=/usr/local/bin/reprobuild-sandbox-launcher --exec=/usr/bin/"),
        Unit.replace("[Service]", "[Socket]"),
        Unit.replace("ProtectSystem=strict",
          "BindReadOnlyPaths=-/opt/x:/usr/"),
        Unit.replace("ProtectSystem=strict", "BindPaths=/usr"),
        Unit.replace("ProtectSystem=strict", "BindPaths=/opt/y:/usr/lib/z"),
        Unit.replace("ProtectSystem=strict", "RootDirectory=/srv/root"),
        Unit.replace("ProtectSystem=strict", "RootImage=/srv/root.img")]:
      expect EAptClosureUnit:
        discard renderUnitWithAptClosure(bad, prefix)
    expect EAptClosureUnit:
      discard renderUnitWithAptClosure(Unit, "/repro/store/a:b")

  test "a list reset, a tmpfs over /usr or a hidden /usr is refused":
    # ``BindReadOnlyPaths=`` with no value resets the list systemd built so
    # far, which would silently drop the closure's own line placed before
    # it; ``TemporaryFileSystem=/usr`` and ``InaccessiblePaths=/usr`` would
    # mask the closure.
    let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot, sampleLock())
    for bad in [
        Unit.replace("ProtectSystem=strict", "BindReadOnlyPaths="),
        Unit.replace("ProtectSystem=strict", "BindPaths="),
        Unit.replace("ProtectSystem=strict", "InaccessiblePaths="),
        Unit.replace("ProtectSystem=strict", "TemporaryFileSystem=/usr"),
        Unit.replace("ProtectSystem=strict",
          "TemporaryFileSystem=/var:ro /usr/lib:ro"),
        Unit.replace("ProtectSystem=strict", "InaccessiblePaths=-/usr/bin"),
        # systemd joins a trailing backslash with the next line, so each of
        # these is the directive above it in disguise: an empty reset, a
        # bind shadowing the closure, a tmpfs over /usr.
        Unit.replace("ProtectSystem=strict", "BindReadOnlyPaths=\\\n"),
        Unit.replace("ProtectSystem=strict",
          "BindReadOnlyPaths=\\\n/opt/other:/usr"),
        Unit.replace("ProtectSystem=strict",
          "TemporaryFileSystem=\\\n# a comment inside the continuation\n/usr")]:
      expect EAptClosureUnit:
        discard renderUnitWithAptClosure(bad, prefix)
    check joinUnitContinuations("A=1 \\\n# c\n2\nB=\\\n") == @["A=1  2", "B= "]
    # The same resets after the rendered lines are what the broker refuses.
    let rendered = renderUnitWithAptClosure(Unit, prefix)
    for bad in [
        rendered & "BindReadOnlyPaths=\n",
        rendered & "TemporaryFileSystem=/usr\n",
        rendered.replace("InaccessiblePaths=-/etc/ld.so.preload\n", ""),
        rendered & "BindReadOnlyPaths=" & prefix & "/usr:/usr\n",
        rendered & "BindReadOnlyPaths=\\\n\n"]:
      expect EAptClosureUnit:
        checkUnitForAptClosure(bad, prefix, rendered = true)
    # Unrelated binds and tmpfs mounts are fine, before and after rendering.
    let fine = Unit.replace("ProtectSystem=strict",
      "ProtectSystem=strict\nBindReadOnlyPaths=/etc/ssl\n" &
      "TemporaryFileSystem=/var/lib/private/x\nInaccessiblePaths=/proc/kmsg")
    checkUnitForAptClosure(renderUnitWithAptClosure(fine, prefix), prefix,
      rendered = true)

  test "comment lines are not read":
    let prefix = aptClosurePrefixPath(AddOnSystemStoreRoot, sampleLock())
    let commented = Unit.replace("ProtectSystem=strict",
      "ProtectSystem=strict\n# RootDirectory=/srv/root\n; BindPaths=/usr\n" &
      "#ExecStart=/x/reprobuild-sandbox-launcher")
    check "RootDirectory" in renderUnitWithAptClosure(commented, prefix)

suite "Add-On apt closure: realisation (spec §8.3 items 2 and 4)":
  test "members are verified, unpacked, folded and unioned":
    let root = scratch("union")
    let (lock, urls) = buildDebs(root, @[
      fileDeb("svc", @[("usr/bin/svc", "svc-binary"),
        ("etc/svc/svc.conf", "conf"), ("usr/share/doc/common", "same")]),
      fileDeb("libold", @[("lib/libold.so.1", "old-lib"),
        ("usr/share/doc/common", "same")],
        links = @[("bin", "usr/bin")])])
    let store = root / "store"
    var count = new int
    let prefix = realiseAptClosure(lock, store, root / "cache",
      localFetcher(urls, count), hostMachine = "armv7l")
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
    storeIsClean(store)
    # The cached archives were consumed (spec §8.3 item 7)...
    check toSeq(walkDir(root / "cache")).len == 0
    # ...and the realisation is idempotent and offline once done.
    let before = count[]
    check realiseAptClosure(lock, store, root / "cache",
      localFetcher(urls, count), hostMachine = "armv7l") == prefix
    check count[] == before

  test "retainDebCache keeps the verified archives":
    let root = scratch("retain")
    let (lock, urls) = buildDebs(root, @[
      fileDeb("svc", @[("usr/bin/svc", "x")])])
    var count = new int
    discard realiseAptClosure(lock, root / "store", root / "cache",
      localFetcher(urls, count), hostMachine = "armv7l",
      retainDebCache = true)
    check fileExists(root / "cache" / (lock.debs[0].sha256 & ".deb"))
    check modeOf(root / "cache") == 0o700

  test "a download that does not match the lock is refused":
    let root = scratch("verify")
    var (lock, urls) = buildDebs(root, @[
      fileDeb("svc", @[("usr/bin/svc", "x")])])
    let path = urls[lock.archive & "/" & lock.debs[0].filename]
    var bytes = readFile(path)
    bytes[^3] = char(ord(bytes[^3]) xor 1)
    writeFile(path, bytes)
    let store = root / "store"
    var count = new int
    expect EAptClosureVerify:
      discard realiseAptClosure(lock, store, root / "cache",
        localFetcher(urls, count), hostMachine = "armv7l")
    check not aptClosureRealised(store, lock)
    check not dirExists(aptDebPrefixPath(store, lock.debs[0]))
    check toSeq(walkDir(root / "cache")).len == 0

  test "two members with different bytes at one path are a refusal":
    let root = scratch("conflict")
    let (lock, urls) = buildDebs(root, @[
      fileDeb("aaa", @[("usr/bin/tool", "one")]),
      fileDeb("bbb", @[("usr/bin/tool", "two")])])
    var count = new int
    expect EAptClosureConflict:
      discard realiseAptClosure(lock, root / "store", root / "cache",
        localFetcher(urls, count), hostMachine = "armv7l")
    check not aptClosureRealised(root / "store", lock)
    storeIsClean(root / "store")

  test "a member cannot place content under another member's symlink":
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
      fileDeb("aaa", @[], links = @[("usr/lib/x", outside)]),
      fileDeb("bbb", @[("usr/lib/x/payload", "p")])])
    var count = new int
    expect EAptClosureConflict:
      discard realiseAptClosure(lock, root / "store", root / "cache",
        localFetcher(urls, count), hostMachine = "armv7l")
    check toSeq(walkDir(outside)).len == 0

  test "a lock for another architecture is refused on this host":
    let root = scratch("arch")
    let (lock, urls) = buildDebs(root, @[
      fileDeb("svc", @[("usr/bin/svc", "x")])])
    var count = new int
    expect EAptClosureHost:
      discard realiseAptClosure(lock, root / "store", root / "cache",
        localFetcher(urls, count), hostMachine = "x86_64")
    check count[] == 0
    check debianArchitectureRunsOn("armhf", "aarch64")
    check debianArchitectureRunsOn("amd64", "x86_64")
    check not debianArchitectureRunsOn("arm64", "armv7l")
    check not debianArchitectureRunsOn("armhf", "")
    check hostMachineName().len > 0

when defined(posix):
  suite "Add-On apt closure: concurrent realisers and crash leftovers":
    ## rpi2, 2026-10-30, reprobuild d7c86107b: two realisers met on one
    ## store (a deploy-agent tick and a second apply with another state
    ## directory). One deleted the other's in-flight ``.deb.part-<pid>`` as
    ## a leftover ("No such file or directory" on the rename), and both
    ## renamed a scratch directory onto the same prefix ("Directory not
    ## empty"). Real processes (``fork``) on the real filesystem; only the
    ## transport is the local fetcher (see the header).

    proc realiseInChild(lock: AptClosureLock; store, cache: string;
                        fetch: AptDebFetcher): Pid =
      result = fork()
      doAssert result >= 0
      if result == 0:
        var code = 0
        try:
          discard realiseAptClosure(lock, store, cache, fetch,
            hostMachine = "armv7l")
        except CatchableError as ex:
          stderr.writeLine("realiser " & $getCurrentProcessId() &
            " failed: " & ex.msg)
          code = 1
        # No atexit handlers: the scratch tree belongs to the parent.
        exitnow(cint(code))

    proc exitCodeOf(pid: Pid): int =
      var status: cint
      doAssert waitpid(pid, status, 0) == pid
      if WIFEXITED(status): int(WEXITSTATUS(status)) else: 128

    test "two processes realising one closure into one store both succeed":
      let root = scratch("concurrent")
      let (lock, urls) = buildDebs(root, @[
        fileDeb("svc", @[("usr/bin/svc", "svc-binary")]),
        fileDeb("libshared", @[("usr/lib/libshared.so.1", "lib")])])
      let store = root / "store"
      let cache = root / "cache"
      # The first realiser holds each download in its ``.part`` file for a
      # while, so the second arrives while one is in flight.
      let slow: AptDebFetcher = proc (url: string; dest: string;
                                       expectedSize: int64) =
        copyFile(urls[url], dest)
        sleep(700)
      let fast: AptDebFetcher = proc (url: string; dest: string;
                                       expectedSize: int64) =
        copyFile(urls[url], dest)
      let a = realiseInChild(lock, store, cache, slow)
      sleep(250)
      let b = realiseInChild(lock, store, cache, fast)
      check exitCodeOf(a) == 0
      check exitCodeOf(b) == 0
      check aptClosureRealised(store, lock)
      check readFile(aptClosurePrefixPath(store, lock) / "usr/bin/svc") ==
        "svc-binary"
      storeIsClean(store)

    test "scratch left by a killed realisation is reclaimed by the next":
      let root = scratch("crashed")
      let (lock, urls) = buildDebs(root, @[
        fileDeb("svc", @[("usr/bin/svc", "svc-binary")])])
      let store = root / "store"
      # What a realiser killed mid-unpack and mid-union leaves behind.
      let debParent = parentDir(aptDebPrefixPath(store, lock.debs[0]))
      let closureParent = parentDir(aptClosurePrefixPath(store, lock))
      for d in [debParent / ".tmp-apt-deb-killed",
                debParent / ".tmp-apt-deb-tar-killed",
                closureParent / ".tmp-apt-closure-killed"]:
        createDir(d / "usr")
        writeFile(d / "usr" / "half", "x")
      var count = new int
      discard realiseAptClosure(lock, store, root / "cache",
        localFetcher(urls, count), hostMachine = "armv7l")
      check aptClosureRealised(store, lock)
      storeIsClean(store)

suite "Add-On apt closure: the unpacker's policy (spec §8.3 item 4)":
  ## Each hostile archive is realised through the public entry point; the
  ## outcome is asserted on the store and on the ``outside`` directory the
  ## entries try to reach.

  proc refused(root: string; entries: seq[TarFixtureEntry]) =
    let outside = root / "outside"
    createDir(outside)
    writeFile(outside / "sentinel", "keep")
    let (lock, urls) = buildDebs(root, @[
      FixtureDeb(name: "evil", entries: @[tarEntry("./", '5', 0o755),
        tarEntry("./usr/", '5', 0o755), tarEntry("./usr/lib/", '5', 0o755)] &
        entries)])
    var count = new int
    expect AptExtractError:
      discard realiseAptClosure(lock, root / "store", root / "cache",
        localFetcher(urls, count), hostMachine = "armv7l")
    check not aptClosureRealised(root / "store", lock)
    check not dirExists(aptDebPrefixPath(root / "store", lock.debs[0]))
    storeIsClean(root / "store")
    # Nothing landed outside, and the sentinel was not replaced.
    check toSeq(walkDir(outside)).mapIt(it.path.extractFilename) ==
      @["sentinel"]
    check readFile(outside / "sentinel") == "keep"

  test "an absolute entry name is refused, not stripped":
    refused(scratch("abs"), @[tarEntry("/usr/lib/evil", content = "x")])

  test "a '..' component is refused":
    refused(scratch("dotdot"), @[
      tarEntry("./usr/lib/../../../outside/evil", content = "x")])

  test "a path through an absolute symlink is refused":
    let root = scratch("symabs")
    refused(root, @[
      tarEntry("./usr/lib/x", '2', 0o777, linkName = root / "outside"),
      tarEntry("./usr/lib/x/evil", content = "x")])

  test "a path through a relative symlink is refused":
    refused(scratch("symrel"), @[
      tarEntry("./usr/lib/x", '2', 0o777, linkName = "../../../../outside"),
      tarEntry("./usr/lib/x/evil", content = "x")])

  test "a file over a symlink is refused":
    let root = scratch("symfile")
    refused(root, @[
      tarEntry("./usr/lib/x", '2', 0o777,
        linkName = root / "outside" / "sentinel"),
      tarEntry("./usr/lib/x", content = "overwrite")])

  test "a top-level directory symlink followed by content is refused":
    let root = scratch("binlink")
    refused(root, @[
      tarEntry("./bin", '2', 0o777, linkName = root / "outside"),
      tarEntry("./bin/evil", content = "x")])

  test "a hard link to a path outside the archive is refused":
    let root = scratch("hardabs")
    refused(root, @[
      tarEntry("./usr/lib/h", '1', linkName = root / "outside" / "sentinel")])
    refused(scratch("hardrel"), @[
      tarEntry("./usr/lib/h", '1', linkName = "../../outside/sentinel")])
    refused(scratch("harddangling"), @[
      tarEntry("./usr/lib/h", '1', linkName = "./usr/lib/not-extracted")])

  test "a device node or a FIFO is refused":
    refused(scratch("chardev"), @[tarEntry("./usr/lib/null", '3', 0o666)])
    refused(scratch("fifo"), @[tarEntry("./usr/lib/pipe", '6', 0o644)])

  test "a duplicate entry is refused, also through a hard link":
    # dpkg refuses a second entry at a name it already extracted; an
    # unpacker that overwrote would let a later entry replace an earlier
    # one and, through a hard link, every other name of that file.
    refused(scratch("dupfile"), @[
      tarEntry("./usr/lib/a", '0', 0o644, "one"),
      tarEntry("./usr/lib/a", '0', 0o644, "two")])
    refused(scratch("duphard"), @[
      tarEntry("./usr/lib/a", '0', 0o644, "one"),
      tarEntry("./usr/lib/b", '1', linkName = "./usr/lib/a"),
      tarEntry("./usr/lib/b", '0', 0o644, "two")])

  test "a NUL inside a pax path or linkpath is refused":
    proc pax(records: string): TarFixtureEntry =
      var payload = ""
      for r in records.split('\n'):
        if r.len == 0: continue
        # <len> <key>=<value>\n, where <len> counts itself.
        var n = r.len + 3
        if n >= 10: inc n
        if n >= 100: inc n
        payload.add($n & " " & r & "\n")
      tarEntry("./PaxHeader", 'x', 0o644, payload)
    refused(scratch("paxnul"), @[
      pax("path=./usr/lib/x\0/../../outside/evil"),
      tarEntry("./ignored", '0', 0o644, "x")])
    refused(scratch("paxlinknul"), @[
      pax("linkpath=./usr/lib/a\0junk"),
      tarEntry("./usr/lib/l", '2', 0o777, linkName = "placeholder")])
    # Positive control: a well-formed pax path is honoured.
    let root = scratch("paxok")
    let (prefix, _) = realiseLocal(root, @[FixtureDeb(name: "ok",
      entries: @[tarEntry("./", '5', 0o755), tarEntry("./usr/", '5', 0o755),
        tarEntry("./usr/lib/", '5', 0o755),
        pax("path=./usr/lib/renamed-by-pax"),
        tarEntry("./usr/lib/original", '0', 0o644, "p")])])
    check readFile(prefix / "usr/lib/renamed-by-pax") == "p"
    check not fileExists(prefix / "usr/lib/original")

  test "the scratch prefix is owner-only until it is published":
    let root = scratch("tmpmode")
    createDir(root / "prefixes" / "x")
    let tmp = tempSibling(root / "prefixes" / "x" / "final", "t")
    check modeOf(tmp) == 0o700
    publishPrefix(tmp, root / "prefixes" / "x" / "final")
    check modeOf(root / "prefixes" / "x" / "final") == 0o755

  test "a hard link to a file in the archive is a hard link in the prefix":
    let root = scratch("hardok")
    let (prefix, _) = realiseLocal(root, @[FixtureDeb(name: "ok",
      entries: @[tarEntry("./", '5', 0o755), tarEntry("./usr/", '5', 0o755),
        tarEntry("./usr/bin/", '5', 0o755),
        tarEntry("./usr/bin/tool", '0', 0o755, "tool"),
        tarEntry("./usr/bin/alias", '1', linkName = "./usr/bin/tool")])])
    check sameFile(prefix / "usr/bin/tool", prefix / "usr/bin/alias")
    check readFile(prefix / "usr/bin/alias") == "tool"

  test "modes are normalised: no setuid, setgid, sticky or group/world write":
    # util-linux ships a 4755 ``su``, passwd a 2755 ``chage``; a hostile
    # archive could ship 0777 directories and 0666 files. Every one lands as
    # 0755 or 0644, through the realiser, in the published prefix. As root
    # (CI, ``unshare -r``) the files are also owned by uid 0.
    let root = scratch("modes")
    let (prefix, lock) = realiseLocal(root, @[FixtureDeb(name: "modes",
      entries: @[tarEntry("./", '5', 0o755), tarEntry("./usr/", '5', 0o755),
        tarEntry("./usr/bin/", '5', 0o777),
        tarEntry("./usr/bin/su", '0', 0o4755, "su"),
        tarEntry("./usr/bin/chage", '0', 0o2755, "chage"),
        tarEntry("./usr/bin/sticky", '0', 0o1755, "sticky"),
        tarEntry("./usr/share/", '5', 0o755),
        tarEntry("./usr/share/w", '0', 0o666, "w"),
        tarEntry("./usr/share/ro", '0', 0o444, "ro"),
        tarEntry("./usr/share/lnk", '2', 0o777, linkName = "w")])])
    check modeOf(prefix / "usr/bin") == 0o755
    check modeOf(prefix / "usr/bin/su") == 0o755
    check modeOf(prefix / "usr/bin/chage") == 0o755
    check modeOf(prefix / "usr/bin/sticky") == 0o755
    check modeOf(prefix / "usr/share/w") == 0o644
    check modeOf(prefix / "usr/share/ro") == 0o644
    check modeOf(prefix) == 0o755
    check modeOf(aptDebPrefixPath(root / "store", lock.debs[0])) == 0o755
    check symlinkExists(prefix / "usr/share/lnk")
    when defined(posix):
      var setid: seq[string] = @[]
      for p in walkDirRec(root / "store", yieldFilter = {pcFile, pcDir}):
        var st: Stat
        doAssert lstat(p.cstring, st) == 0
        if (st.st_mode.cint and (S_ISUID or S_ISGID or S_ISVTX or S_IWGRP or
                                 S_IWOTH)) != 0:
          setid.add(p)
        if geteuid() == 0:
          check st.st_uid == 0 and st.st_gid == 0
      check setid.len == 0
      # verifyHardenedTree is the invariant check: a tree with a setuid file
      # fails it (positive control for the check itself).
      let bad = root / "bad"
      createDir(bad / "usr")
      writeFile(bad / "usr/su", "x")
      check chmod((bad / "usr/su").cstring, Mode(0o4755)) == 0
      expect AptExtractError:
        verifyHardenedTree(bad, "bad")

# ---------------------------------------------------------------------------
# A one-thread canned HTTP server for the bounded downloader
# ---------------------------------------------------------------------------

type CannedServer = object
  port: int

proc serveCanned(port: int) {.thread.} =
  ## HTTP/1.0 responder: ``/big`` is 4096 bytes with a true Content-Length,
  ## ``/short`` claims 4096 bytes and sends 10, ``/redir`` is a 302 to
  ## ``/ok``, ``/ok`` is ``hello``, ``/quit`` stops the server.
  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port), "127.0.0.1")
  listener.listen()
  var running = true
  while running:
    var client: Socket
    listener.accept(client)
    var line = ""
    client.readLine(line, timeout = 5000)
    var path = ""
    let parts = line.splitWhitespace()
    if parts.len >= 2: path = parts[1]
    while true:
      var h = ""
      client.readLine(h, timeout = 5000)
      if h.len == 0 or h == "\r\n": break
    var body = ""
    var status = "200 OK"
    var extra = ""
    var declared = -1
    case path
    of "/big": body = "B".repeat(4096)
    of "/short":
      body = "S".repeat(10)
      declared = 4096
    of "/redir":
      status = "302 Found"
      extra = "Location: /ok\r\n"
    of "/ok": body = "hello"
    of "/err":
      status = "404 Not Found"
      body = "E".repeat(200_000)
    of "/quit": running = false
    else: status = "404 Not Found"
    let length = if declared >= 0: declared else: body.len
    client.send("HTTP/1.0 " & status & "\r\nContent-Length: " & $length &
      "\r\n" & extra & "Connection: close\r\n\r\n" & body)
    client.close()
  listener.close()

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

suite "Add-On apt closure: bounded download (spec §8.3 item 2)":
  test "a body over the cap, a wrong length and a redirect":
    let port = freePort()
    var th: Thread[int]
    createThread(th, serveCanned, port)
    let base = "http://127.0.0.1:" & $port
    let root = scratch("download")
    # Wait for the listener.
    for _ in 0 ..< 100:
      try:
        let probe = newSocket()
        probe.connect("127.0.0.1", Port(port), timeout = 200)
        probe.send("GET /ok HTTP/1.0\r\n\r\n")
        probe.close()
        break
      except CatchableError:
        sleep(50)
    # Content-Length above the cap: refused before the body is read.
    expect IOError:
      discard downloadBounded(base & "/big", root / "a", maxBytes = 1000)
    check not fileExists(root / "a")
    # Content-Length differing from the expected size: refused.
    expect IOError:
      discard downloadBounded(base & "/big", root / "b", maxBytes = 1 shl 20,
        expectedSize = 1000)
    check not fileExists(root / "b")
    # A short body under a larger declared length: refused by the transport.
    expect IOError:
      discard downloadBounded(base & "/short", root / "c", maxBytes = 1 shl 20)
    # Exact size: accepted.
    check downloadBounded(base & "/big", root / "d", maxBytes = 1 shl 20,
      expectedSize = 4096) == 4096
    check getFileSize(root / "d") == 4096
    # A redirect is followed, and the production fetcher caps at the size.
    check downloadBounded(base & "/redir", root / "e", maxBytes = 100) == 5
    check readFile(root / "e") == "hello"
    # An error response with a large body is not drained past 64 KiB: the
    # refusal names the cap, not the 404 that reading it all would give.
    var errMsg = ""
    try:
      discard downloadBounded(base & "/err", root / "err", maxBytes = 1 shl 20)
    except IOError as ex:
      errMsg = ex.msg
    check "exceeds 65536" in errMsg
    httpDebFetcher()(base & "/ok", root / "f", 5)
    check readFile(root / "f") == "hello"
    expect IOError:
      httpDebFetcher()(base & "/big", root / "g", 5)
    discard downloadBounded(base & "/quit", root / "h", maxBytes = 10)
    joinThread(th)

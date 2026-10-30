## Add-On Mode ``package(apt, ...)`` closures — a real armhf Debian 13 closure.
##
## Governing spec: ``reprobuild-pm/spec/ReproOS-Add-On-Mode.md`` §8.3, "How a
## closure is pinned, stored and bound", items 2, 4 and 6.
##
## The fixture lock ``fixtures/apt_closure/debian-trixie-20261001-armhf-node-exporter.lock``
## pins the closure of ``prometheus-node-exporter`` (with the Essential set)
## in Debian 13 "trixie" for ``armhf``, as published on
## ``snapshot.debian.org`` at ``20261001T000000Z``. It was written by
## ``repro-harvest-apt --emit-lock`` after verifying that ``InRelease``
## against ``recipes/catalog/foreign/apt/keys/archives/debian-archive-trixie.gpg``.
## A snapshot never changes, so the lock — and every ``.deb`` it names —
## stays fetchable and byte-identical; this is why the test pins Debian's
## snapshot rather than the moving Raspbian archive the dogfood host uses
## (same suite and architecture, same realiser code path).
##
## NO MOCKS. The ``.deb``s are downloaded over HTTP from the real archive by
## the realiser's own fetcher, verified against the lock, and unpacked with
## the host ``tar``. Downloads land in a persistent, content-addressed cache
## (``$REPRO_TEST_APT_DEB_CACHE``, default
## ``<user cache>/reprobuild-test-fixtures/apt-debs``) so only the first run
## on a machine pays for the ~29 MB; every later use is re-verified against
## the lock, so a corrupted cache entry is refetched, never trusted.

import std/[os, sequtils, strutils, times, unittest]
when defined(posix):
  import std/posix

import repro_dsl_stdlib/packages/apt_closure
import repro_dsl_stdlib/packages/apt_jammy
from repro_test_support/process_fixtures import releaseDirAtProcessExit

const LockText = staticRead(
  "fixtures/apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

proc debCache(): string =
  result = getEnv("REPRO_TEST_APT_DEB_CACHE")
  if result.len == 0:
    result = getCacheDir() / "reprobuild-test-fixtures" / "apt-debs"
  createDir(result)

proc freshStore(tag: string): string =
  result = getTempDir() / ("t-addon-apt-trixie-" & tag & "-" &
    $getCurrentProcessId())
  releaseDirAtProcessExit(result)
  if dirExists(result): removeDir(result)
  createDir(result)

proc elfIsArmhf(path: string): bool =
  ## ELF32, little-endian, ``e_machine == EM_ARM`` (40), hard-float ABI
  ## flag (``EF_ARM_ABI_FLOAT_HARD`` 0x400) in ``e_flags``.
  ## https://refspecs.linuxfoundation.org/elf/gabi4+/ch4.eheader.html
  let b = readFile(path)
  if b.len < 52 or b[0 .. 3] != "\x7fELF": return false
  let eMachine = ord(b[18]) or (ord(b[19]) shl 8)
  let eFlags = ord(b[36]) or (ord(b[37]) shl 8) or (ord(b[38]) shl 16) or
    (ord(b[39]) shl 24)
  ord(b[4]) == 1 and ord(b[5]) == 1 and eMachine == 40 and
    (eFlags and 0x400) != 0

proc usrSnapshot(): seq[string] =
  ## Every path under the host's ``/usr`` with its size and mtime.
  for p in walkDirRec("/usr", yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                              pcLinkToDir},
                      followFilter = {pcDir}):
    try:
      let i = getFileInfo(p, followSymlink = false)
      result.add(p & " " & $i.size & " " & $i.lastWriteTime.toUnix)
    except OSError:
      result.add(p & " ?")

suite "Add-On apt closure: real Debian trixie armhf closure":
  test "the pinned node-exporter closure is realised into a store prefix":
    let lock = parseAptClosureLock(LockText)
    check lock.architecture == "armhf"
    check lock.suite == "trixie"
    check lock.roots == @["prometheus-node-exporter"]
    check lock.debs.anyIt(it.name == "libc6")
    let usrBefore = usrSnapshot()
    let store = freshStore("realise")
    let prefix = realiseAptClosure(lock, store, debCache())

    # The path is the one the planner renders into the unit, offline.
    check prefix == aptClosurePrefixPath(store, lock)
    check aptClosureRealised(store, lock)

    # Every member is unpacked into its own content-addressed prefix whose
    # completion marker carries the lock's SHA-256, and the cached archive
    # it came from hashes to that SHA-256.
    for d in lock.debs:
      let dp = aptDebPrefixPath(store, d)
      check readFile(dp / ".repro-apt-deb") == d.sha256 & "\n"
      check sha256OfFile(debCache() / (d.sha256 & ".deb")) == d.sha256

    # The closure holds an armhf Debian userland: the daemon, the loader its
    # PT_INTERP names (through the base's /lib -> usr/lib link), libc, and
    # the essential /bin/sh.
    let exporter = prefix / "usr/bin/prometheus-node-exporter"
    check fileExists(exporter)
    check elfIsArmhf(exporter)
    check fileExists(prefix / "usr/lib/ld-linux-armhf.so.3")
    check fileExists(prefix / "usr/lib/arm-linux-gnueabihf/libc.so.6")
    check elfIsArmhf(prefix / "usr/lib/arm-linux-gnueabihf/libc.so.6")
    check fileExists(prefix / "usr/bin/dash")
    check symlinkExists(prefix / "usr/bin/sh")
    # The daemon is shared with its member prefix, not copied.
    for d in lock.debs:
      if d.name == "prometheus-node-exporter":
        check sameFile(exporter,
          aptDebPrefixPath(store, d) / "usr/bin/prometheus-node-exporter")

    # Only ``usr`` and ``etc`` (and the marker) at the top: the base owns
    # /bin, /lib, /sbin as merged-/usr links, and /var, /run, ... are the
    # host's.
    var top: seq[string] = @[]
    for kind, p in walkDir(prefix): top.add(p.extractFilename)
    check top.len == 3
    check "usr" in top and "etc" in top and ".repro-apt-closure" in top

    # No setuid/setgid bit anywhere (util-linux's ``su`` is setuid in the
    # archive), no special files.
    when defined(posix):
      var setid: seq[string] = @[]
      for p in walkDirRec(prefix, yieldFilter = {pcFile}):
        var st: Stat
        doAssert lstat(p.cstring, st) == 0
        if S_ISREG(st.st_mode) and
            (st.st_mode.cint and (S_ISUID or S_ISGID)) != 0:
          setid.add(p)
      check setid.len == 0

    # The host's /usr is exactly as it was.
    check usrSnapshot() == usrBefore

    # A second realisation is a no-op that reuses the prefix.
    check realiseAptClosure(lock, store, debCache(),
      proc (url, dest: string) =
        raise newException(IOError, "unexpected fetch of " & url)) == prefix

  test "the rendered unit binds the realised prefix":
    let lock = parseAptClosureLock(LockText)
    let unit = "[Service]\nExecStart=/usr/bin/prometheus-node-exporter\n" &
      "DynamicUser=yes\n"
    let rendered = renderUnitForAptClosureLock(unit, LockText)
    check ("BindReadOnlyPaths=" & aptClosurePrefixPath(AddOnSystemStoreRoot,
      lock) & "/usr:/usr") in rendered.splitLines()
    check "ExecStart=/usr/bin/prometheus-node-exporter" in rendered.splitLines()

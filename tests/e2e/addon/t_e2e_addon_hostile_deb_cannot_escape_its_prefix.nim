## Gate ``e2e_addon_hostile_deb_cannot_escape_its_prefix``.
##
## The apt closure realiser unpacks each pinned ``.deb``'s ``data.tar`` with
## its own tar reader, never the host ``tar`` (whose handling of a hostile
## entry depends on its version and on running as root). This gate runs that
## reader where it is used -- the add-on's apply on each base of the matrix
## -- against a fixture ``.deb`` whose ``data.tar`` holds
##
##   ./usr/d              -> /var/tmp/repro-g37-outside   (a symlink)
##   ./usr/d/x-g37-escaped                               (a file through it)
##
## with ``/var/tmp/repro-g37-outside`` an existing directory outside the
## store. The apply must refuse the closure, naming the symbolic link, and
## nothing may appear outside the prefix: the outside directory keeps only
## its sentinel, no ``x-g37-escaped`` exists anywhere on the root
## filesystem, and no prefix of the hostile member is published.
##
## Vacuity guard: on the same host, a well-formed fixture ``.deb`` pinned
## the same way is realised by the same apply path (its file is in the
## closure prefix the unit binds), so a refusal is the reader's policy, not
## a realiser that cannot run.
##
## Falsifying mutation ``apt-deb-reader-follows-symlinks``
## (``REPRO_ADDON_MUTATION``): the realiser's ``data.tar`` reader writes
## through the symlink component and the union builder's link check is off;
## ``x-g37-escaped`` then lands in the outside directory and the gate is red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_addon_hostile_deb_cannot_escape_its_prefix``). Bases:
## ``REPRO_ADDON_BASES`` (default: the amd64 matrix).
##
## *Mocking.* None of behaviour. The fixture ``.deb`` files are built here
## byte for byte (a hostile tar stream is not something a well-behaved
## ``dpkg-deb`` writes) and seeded into the realiser's ``.deb`` cache, where
## it re-verifies them against the lock exactly as it verifies a download;
## the lock's archive URL is therefore never contacted. Everything else is
## the real add-on binary on a real distribution image.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_dsl_stdlib/packages/apt_closure
import repro_dsl_stdlib/packages/apt_index
import repro_dsl_stdlib/packages/apt_jammy

import ./addon_testbed

const
  Gate = "e2e_addon_hostile_deb_cannot_escape_its_prefix"
  Outside = "/var/tmp/repro-g37-outside"
  Escaped = "x-g37-escaped"
  OkFile = "usr/share/repro-g37/ok.txt"
  OkContent = "well-formed fixture\n"

# ---------------------------------------------------------------------------
# Fixture .deb files: a ustar stream inside an ar container.
# ---------------------------------------------------------------------------

type TarEntry = tuple[name: string; typeflag: char; mode: int;
                      content, linkName: string]

proc octal(v: int64; width: int): string = toOct(v, width - 1) & "\0"

proc tarBytes(entries: seq[TarEntry]): string =
  ## A ustar stream (owners 0:0, two zero blocks at the end), as
  ## ``dpkg-deb`` writes one, but with whatever entries are given.
  for e in entries:
    var h = "\0".repeat(512)
    h[0 ..< e.name.len] = e.name
    h[100 ..< 108] = octal(e.mode, 8)
    h[108 ..< 116] = octal(0, 8)
    h[116 ..< 124] = octal(0, 8)
    let size = if e.typeflag == '0': e.content.len else: 0
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
      result.add("\0".repeat((512 - size mod 512) mod 512))
  result.add("\0".repeat(1024))

proc arMember(name, payload: string): string =
  var header = name & "/"
  header.add(" ".repeat(16 - header.len))
  header.add("0".alignLeft(12) & "0".alignLeft(6) & "0".alignLeft(6) &
    "100644".alignLeft(8) & ($payload.len).alignLeft(10) & "`\n")
  result = header & payload
  if (payload.len and 1) == 1: result.add('\n')

proc writeDeb(path: string; entries: seq[TarEntry]) =
  writeFile(path, "!<arch>\n" & arMember("debian-binary", "2.0\n") &
    arMember("data.tar", tarBytes(entries)))

proc dir(name: string): TarEntry = (name, '5', 0o755, "", "")

proc fixtureLock(name, debPath: string): AptClosureLock =
  ## A one-member closure lock pinning ``debPath`` by size and SHA-256.
  AptClosureLock(
    archive: "http://fixture.invalid/debian", suite: "fixture",
    components: @["main"], architecture: "amd64", snapshot: "",
    inReleaseSha256: "c".repeat(64),
    indexes: @[AptIndexDigest(path: "main/binary-amd64/Packages.xz",
                              sha256: "d".repeat(64))],
    roots: @[name],
    debs: @[AptLockedDeb(name: name, version: "1.0-1", architecture: "amd64",
      filename: "pool/main/" & name & "_1.0-1_amd64.deb",
      size: getFileSize(debPath), sha256: sha256OfFile(debPath))])

proc profile(unit, lockText: string): string =
  ## One disabled unit bound to the closure: the switch realises the
  ## closure in step 1 and never starts the unit.
  "systemd.systemUnit {\n  name = \"" & unit & "\"\n" &
  "  content = \"[Unit]\nDescription=G37 fixture\n[Service]\n" &
    "Type=oneshot\nExecStart=/usr/bin/true\n\"\n" &
  "  enabled = false\n" &
  "  aptClosureLock = \"" & lockText & "\"\n}\n"

proc seedCache(g: Guest; lock: AptClosureLock; debPath: string) =
  discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                AddOnAptDebCacheDir)
  g.copyTo(debPath, AddOnAptDebCacheDir & "/" & lock.debs[0].sha256 & ".deb")

proc runBase(b: BaseImage; record: JsonNode; work: string): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let goodDeb = work / "g37-good.deb"
    writeDeb(goodDeb, @[dir("./"), dir("./usr/"), dir("./usr/share/"),
      dir("./usr/share/repro-g37/"),
      ("./" & OkFile, '0', 0o644, OkContent, "")])
    let hostileDeb = work / "g37-hostile.deb"
    writeDeb(hostileDeb, @[dir("./"), dir("./usr/"),
      ("./usr/d", '2', 0o777, "", Outside),
      ("./usr/d/" & Escaped, '0', 0o644, "escaped\n", "")])
    let goodLock = fixtureLock("g37-good", goodDeb)
    let hostileLock = fixtureLock("g37-hostile", hostileDeb)
    record["hostileDebSha256"] = %hostileLock.debs[0].sha256

    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails

    # Vacuity guard: the same path realises a well-formed member.
    g.seedCache(goodLock, goodDeb)
    let good = g.applyProfile(repro, "g37-good",
      profile("repro-g37-good.service", renderAptClosureLock(goodLock)))
    step("a well-formed fixture .deb is realised", good.exitCode == 0,
         good.stdout & good.stderr)
    let okPath = aptClosurePrefixPath(AddOnSystemStoreRoot, goodLock) / OkFile
    step("its file is in the closure prefix the unit binds",
         g.run("cat " & okPath & " 2>&1") == OkContent, okPath)

    # The hostile member.
    discard g.run("mkdir -p " & Outside & " && echo keep > " & Outside &
                  "/sentinel")
    g.seedCache(hostileLock, hostileDeb)
    let bad = g.applyProfile(repro, "g37-hostile",
      profile("repro-g37-hostile.service", renderAptClosureLock(hostileLock)))
    let said = bad.stdout & bad.stderr
    step("the apply refuses the hostile closure", bad.exitCode != 0, said)
    step("the refusal names the symbolic link",
         "symbolic link" in said, said)
    let outside = g.run("ls -A " & Outside).strip()
    step("the outside directory holds only its sentinel",
         outside == "sentinel", outside)
    step("the sentinel is unchanged",
         g.run("cat " & Outside & "/sentinel").strip() == "keep", "")
    let found = g.run("find / -xdev -name " & Escaped & " 2>/dev/null").strip()
    step("no " & Escaped & " exists anywhere on the root filesystem",
         found.len == 0, found)
    let memberPrefix = aptDebPrefixPath(AddOnSystemStoreRoot,
                                        hostileLock.debs[0])
    step("no prefix of the hostile member is published",
         g.exec("test ! -e " & memberPrefix).exitCode == 0, memberPrefix)
    step("no closure prefix of the hostile lock is published",
         g.exec("test ! -e " & aptClosurePrefixPath(AddOnSystemStoreRoot,
           hostileLock)).exitCode == 0, "")
    discard g.run("rm -rf " & Outside)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite Gate:
  test "a .deb that writes through its own symlink is refused on every base":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      let work = getTempDir() / ("repro-g37-" & $getCurrentProcessId())
      createDir(work)
      defer: removeDir(work)
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record, work)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

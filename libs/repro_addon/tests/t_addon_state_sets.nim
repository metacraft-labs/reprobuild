## Declared state sets (ReproOS Add-On Mode §11.1 step 2,
## ``repro_addon/state_sets``): the set a profile declares, the tree digest
## a directory is verified by, and backup, verify and restore over real
## directories and the host's real ``tar``.
##
## Falsifying mutations (``scripts/run_addon_unit_mutation.sh
## t_addon_state_sets <mutation>``): ``state-units-not-checked`` (a backup
## or restore runs while a unit of the set runs), ``state-archive-unchecked``
## (a restore reads an archive the manifest does not name) and
## ``state-restore-unverified`` (a staged tree is renamed into place without
## its digest checked) and ``apply-ignores-carried-state`` (an apply starts
## a unit whose carried state is not restored) each turn this test red.
##
## *Mocking.* Two seams, both justified:
## - the unit liveness (``AlivenessFn``): the production check reads a
##   unit's cgroup through systemd, which a unit test has no unit for. The
##   real check runs in the VM gates ``e2e_addon_adopt_hand_configured_service``
##   and the conversion gate, against real units;
## - the hold (``hold = false``): ``systemctl mask --runtime`` needs root
##   and a running systemd; the VM gates run it.
## The directories live under a temporary ``root`` instead of ``/``
## (the same parameter a conversion uses for a mounted target root).

import std/[json, os, posix, strutils, unittest]

import repro_infra
from repro_test_support import testCaseScratchSlug
import repro_addon/[state_sets, transitions]

const Profile = """systemd.systemUnit {
  name = "app.service"
  content = "[Service]
ExecStart=/bin/true
"
  stateDirectories = ["carry:/var/lib/app", "keep:/srv/media"]
}

systemd.systemUnit {
  name = "worker.service"
  content = "[Service]
ExecStart=/bin/true
"
  stateDirectories = ["carry:/var/lib/app"]
}
"""

proc stopped(): AlivenessFn =
  result = proc (u: string): UnitAliveness = uaEmpty

proc running(which: string): AlivenessFn =
  result = proc (u: string): UnitAliveness =
    if u == which: uaPopulated else: uaEmpty

proc unknown(): AlivenessFn =
  result = proc (u: string): UnitAliveness = uaUnknown

var scratch = getTempDir() / ("t_addon_state_sets" & testCaseScratchSlug())

proc fresh(name: string): string =
  result = scratch / name
  removeDir(result)
  createDir(result)

proc populate(root: string) =
  createDir(root / "var/lib/app/db")
  writeFile(root / "var/lib/app/db/data.sqlite", "rows\n")
  writeFile(root / "var/lib/app/config.json", "{}\n")
  setFilePermissions(root / "var/lib/app/config.json", {fpUserRead, fpUserWrite})
  createSymlink("db/data.sqlite", root / "var/lib/app/current")
  createDir(root / "srv/media")
  writeFile(root / "srv/media/a.jpg", "jpeg")

suite "state sets":
  test "the set: each directory once, with every unit naming it":
    let s = stateSetOf(parseSystemProfile(Profile))
    check s.len == 2
    check s[0].path == "/srv/media" and s[0].disposition == sdKeep and
      s[0].units == @["app.service"]
    check s[1].path == "/var/lib/app" and s[1].disposition == sdCarry and
      s[1].units == @["app.service", "worker.service"]

  test "the tree digest sees content, mode, links and new entries, not time":
    let r = fresh("digest")
    populate(r)
    let d = r / "var/lib/app"
    let base = treeDigest(d)
    check base.startsWith("sha256:")
    check treeDigest(d) == base
    discard utimes((d / "config.json").cstring, nil)
    check treeDigest(d) == base
    writeFile(d / "config.json", "{ }\n")
    check treeDigest(d) != base
    writeFile(d / "config.json", "{}\n")
    check treeDigest(d) == base
    setFilePermissions(d / "config.json", {fpUserRead})
    check treeDigest(d) != base
    setFilePermissions(d / "config.json", {fpUserRead, fpUserWrite})
    removeFile(d / "current")
    createSymlink("db", d / "current")
    check treeDigest(d) != base
    removeFile(d / "current")
    createSymlink("db/data.sqlite", d / "current")
    check treeDigest(d) == base
    writeFile(d / "db/new", "")
    check treeDigest(d) != base
    removeFile(d / "db/new")
    check mkfifo((d / "pipe").cstring, 0o600) == 0
    expect StateSetError:
      discard treeDigest(d)
    removeFile(d / "pipe")

  test "backup refuses while a unit of the set runs or is not known stopped":
    let r = fresh("refuse")
    populate(r)
    let p = parseSystemProfile(Profile)
    for alive in [running("worker.service"), unknown()]:
      expect StateSetError:
        discard backupStateSet(p, r / "out", "h", alive, hold = false, root = r)
      check not dirExists(r / "out")

  test "backup, verify and restore carry the tree and keep only a digest":
    let src = fresh("src")
    populate(src)
    let p = parseSystemProfile(Profile)
    let m = backupStateSet(p, src / "out", "h1", stopped(), hold = false,
                           root = src)
    check m.entries.len == 2
    let man = parseJson(readFile(src / "out" / ManifestFileName))
    check man["schema"].getStr() == ManifestSchema
    check man["entries"][0]["disposition"].getStr() == "keep"
    check man["entries"][0]["archive"].getStr() == ""
    check fileExists(src / "out" / man["entries"][1]["archive"].getStr())
    check verifyEntries(m, root = src).differing.len == 0
    # A directory that changes after the backup fails the verify that runs
    # before the conversion destroys the source.
    writeFile(src / "var/lib/app/db/data.sqlite", "rows+1\n")
    check verifyEntries(m, root = src).differing ==
      @["/var/lib/app: " & treeDigest(src / "var/lib/app") &
        " (manifest " & m.entries[1].digest & ")"]
    writeFile(src / "var/lib/app/db/data.sqlite", "rows\n")

    let dst = fresh("dst")
    createDir(dst / "var/lib")
    check pendingCarriedState(src / "out").len == 1
    expect StateSetError:
      discard restoreStateSet(src / "out", running("app.service"), root = dst)
    check not dirExists(dst / "var/lib/app")
    check restoreStateSet(src / "out", stopped(), root = dst) == @["/var/lib/app"]
    check treeDigest(dst / "var/lib/app") == treeDigest(src / "var/lib/app")
    check pendingCarriedState(src / "out").len == 0
    for kind, path in walkDir(dst / "var/lib"):
      check not extractFilename(path).startsWith(".repro-restore-")
    # Idempotent: a second restore finds the tree there and restores none.
    check restoreStateSet(src / "out", stopped(), root = dst).len == 0
    # An empty placeholder (a tmpfiles rule ran first) is replaced.
    let dst2 = fresh("dst2")
    createDir(dst2 / "var/lib/app")
    check restoreStateSet(src / "out", stopped(), root = dst2) == @["/var/lib/app"]

  test "restore refuses a different tree, a bad archive and a bad digest":
    let src = fresh("src2")
    populate(src)
    let p = parseSystemProfile(Profile)
    discard backupStateSet(p, src / "out", "h1", stopped(), hold = false,
                           root = src)
    let other = fresh("other")
    createDir(other / "var/lib/app")
    writeFile(other / "var/lib/app/x", "someone else's")
    expect StateSetError:
      discard restoreStateSet(src / "out", stopped(), root = other)
    check readFile(other / "var/lib/app/x") == "someone else's"

    # An archive that is not the manifest's is never read.
    let man = parseJson(readFile(src / "out" / ManifestFileName))
    let archive = src / "out" / man["entries"][1]["archive"].getStr()
    let good = readFile(archive)
    let evil = fresh("evil")
    createDir(evil / "var/lib/app")
    writeFile(evil / "var/lib/app/config.json", "{\"admin\":true}\n")
    let evilOut = fresh("evil-out")
    discard backupStateSet(parseSystemProfile("""systemd.systemUnit {
  name = "app.service"
  content = "x"
  stateDirectories = ["carry:/var/lib/app"]
}
"""), evilOut / "o", "h", stopped(), hold = false, root = evil)
    let evilMan = parseJson(readFile(evilOut / "o" / ManifestFileName))
    writeFile(archive, readFile(evilOut / "o" / evilMan["entries"][0]["archive"].getStr()))
    let d1 = fresh("d1")
    var why = ""
    try:
      discard restoreStateSet(src / "out", stopped(), root = d1)
    except StateSetError as e:
      why = e.msg
    # Refused for the archive, before a byte of it was read -- not later,
    # for the tree it would have produced.
    check "archive of /var/lib/app does not match the manifest" in why
    check not dirExists(d1 / "var/lib/app")
    for kind, path in walkDir(d1 / "var/lib"):
      check false
    writeFile(archive, good)

    # A tree whose digest is not the manifest's is never renamed into place
    # (the manifest's digest edited here; the archive is intact).
    var edited = man
    edited["entries"][1]["digest"] = %("sha256:" & repeat('0', 64))
    writeFile(src / "out" / ManifestFileName, $edited)
    let d2 = fresh("d2")
    expect StateSetError:
      discard restoreStateSet(src / "out", stopped(), root = d2)
    check not dirExists(d2 / "var/lib/app")
    check pendingCarriedState(src / "out").len == 1

  test "an apply waits for carried state: refused until it is restored":
    let src = fresh("pend-src")
    populate(src)
    let p = parseSystemProfile(Profile)
    discard backupStateSet(p, src / "out", "h1", stopped(), hold = false,
                           root = src)
    let why = carriedStateRefusal(p, src / "out")
    check why.startsWith("ECarriedStatePending")
    check "/var/lib/app (app.service)" in why
    # A profile that declares none of the set's units is not held up.
    check carriedStateRefusal(parseSystemProfile("""systemd.systemUnit {
  name = "other.service"
  content = "x"
}
"""), src / "out") == ""
    # No manifest at all: nothing pending.
    check carriedStateRefusal(p, fresh("no-manifest")) == ""
    # An unreadable manifest refuses (fail closed).
    let broken = fresh("broken")
    writeFile(broken / ManifestFileName, "{")
    check carriedStateRefusal(p, broken).len > 0
    let dst = fresh("pend-dst")
    discard restoreStateSet(src / "out", stopped(), root = dst)
    check carriedStateRefusal(p, src / "out") == ""

  test "owners: recorded by name, and a host that disagrees refuses":
    let src = fresh("own-src")
    populate(src)
    let me = $getuid()
    let grp = $getgid()
    createDir(src / "etc")
    writeFile(src / "etc/passwd", "root:x:0:0::/root:/bin/sh\napp:x:" & me &
      ":" & grp & "::/var/lib/app:/usr/sbin/nologin\n")
    writeFile(src / "etc/group", "root:x:0:\napp:x:" & grp & ":\n")
    let m = backupStateSet(parseSystemProfile(Profile), src / "out", "h1",
                           stopped(), hold = false, root = src)
    check ("uid:" & me, "app") in m.entries[1].owners
    check ("gid:" & grp, "app") in m.entries[1].owners
    check parseStateManifest(readFile(src / "out" / ManifestFileName)).
      entries[1].owners == m.entries[1].owners
    # The same name with another id on the converted host: refused.
    let other = fresh("own-other")
    createDir(other / "etc")
    writeFile(other / "etc/passwd", "app:x:" & $(getuid().int + 1) & ":" &
      grp & "::/:/bin/sh\n")
    expect StateSetError:
      discard restoreStateSet(src / "out", stopped(), root = other)
    check not dirExists(other / "var/lib/app")
    # The id held by another name: refused too.
    let taken = fresh("own-taken")
    createDir(taken / "etc")
    writeFile(taken / "etc/passwd", "someone:x:" & me & ":" & grp & "::/:/bin/sh\n")
    expect StateSetError:
      discard restoreStateSet(src / "out", stopped(), root = taken)
    # No such account yet (it is created later, with the declared id): fine.
    let fresh2 = fresh("own-none")
    check restoreStateSet(src / "out", stopped(), root = fresh2) ==
      @["/var/lib/app"]

  test "a manifest is input: paths and archives are checked":
    for bad in [
        """{"schema":"other","entries":[]}""",
        """{"schema":"repro-state-set/1","entries":[{"path":"/etc/x","disposition":"keep","digest":"sha256:0"}]}""",
        """{"schema":"repro-state-set/1","entries":[{"path":"/var/lib/x","disposition":"carry","digest":"sha256:0","archive":"../x.tar","archiveSha256":"""" & repeat('0', 64) & """"}]}""",
        """{"schema":"repro-state-set/1","entries":[{"path":"/var/lib/x","disposition":"move","digest":"sha256:0"}]}"""]:
      expect StateSetError:
        discard parseStateManifest(bad)

  test "the archive reader writes nothing outside its staging directory":
    proc entry(t, rel, data: string): string =
      t & " 0755 " & $getuid() & " " & $getgid() & " " & $rel.len & " " &
        $data.len & "\n" & rel & data
    let outside = fresh("outside")
    let cases = [
      entry("d", ".", "") & entry("f", "../escape", "x"),
      entry("d", ".", "") & entry("f", "/abs", "x"),
      entry("d", ".", "") & entry("l", "ln", outside) & entry("f", "ln/x", "x"),
      entry("d", ".", "") & entry("f", "a/x", "x"),
      entry("f", "x", "x"),
      entry("d", ".", "") & entry("d", ".", ""),
      entry("d", ".", "") & entry("f", "a", "x") & entry("f", "a", "y"),
      entry("d", ".", "") & "f 0644 0 0 1 99\nb"]
    for i, c in cases:
      let a = scratch / ("bad-" & $i & ".rsa")
      writeFile(a, "REPRO-STATE-ARCHIVE 1\n" & c)
      let st = fresh("stage-" & $i)
      expect StateSetError:
        extractStateArchive(a, st)
      check not fileExists(scratch / "escape") and not fileExists("/abs")
      check not fileExists(outside / "x")

removeDir(scratch)

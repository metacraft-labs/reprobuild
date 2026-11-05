## Declared state sets (ReproOS Add-On Mode §11.1 step 2,
## ``repro_addon/state_sets``): the set a profile declares, the tree digest
## a directory is verified by, backup, verify and restore over real
## directories with Reprobuild's own state archive, and the carried-state
## check every apply makes (``repro_infra/carried_state``).
##
## Falsifying mutations (``scripts/run_addon_unit_mutation.sh
## t_addon_state_sets <mutation>``), each turning this test red:
## ``state-units-not-checked`` (a backup or restore runs while a unit of the
## set runs), ``state-archive-unchecked`` (a restore reads an archive the
## manifest does not name), ``state-restore-unverified`` (a staged tree is
## renamed into place without its digest checked),
## ``apply-ignores-carried-state`` (an apply reaches carried state that is
## not restored), ``pending-by-receipt-only`` (a receipt for another root
## clears the wait), ``carried-reach-by-unit-name`` (a renamed unit that
## keeps the directory is not held up), ``owner-ids-unchecked`` (a carried
## tree's owners are not compared with the accounts the apply uses),
## ``apply-ignores-hold`` (an apply runs under a backup's hold),
## ``hardlinks-unchecked`` (a hard link passes the digest),
## ``restore-leaves-staging`` (a retried restore leaves the old staging
## directory) and ``restore-writes-dense`` (a restored file is not sparse).
##
## *Mocking.* Two seams, both justified:
## - the unit liveness (``AlivenessFn``): the production check reads a
##   unit's cgroup through systemd, which a unit test has no unit for. The
##   real check runs in the VM gates ``e2e_addon_adopt_hand_configured_service``
##   and the conversion gate, against real units;
## - the hold (``hold = false``): writing the drop-in and asking systemd
##   whether it loaded it needs root and a running systemd; the VM gates
##   run it. The apply's refusal under a hold is tested here over a hold
##   file under a temporary root.
## The directories live under a temporary ``root`` instead of ``/``
## (the same parameter a conversion uses for a mounted target root).

import std/[json, os, posix, strutils, unittest]

import repro_infra
from repro_test_support import testCaseScratchSlug
import repro_addon/[addon_apply, state_sets, transitions]

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

const
  OldValidator = """systemd.systemUnit {
  name = "eth-validator.service"
  content = "[Service]
ProtectSystem=strict
ExecStart=/bin/true
"
  stateDirectories = ["carry:/var/lib/ethereum/validator"]
}
"""
  RenamedValidator = OldValidator.replace("eth-validator.service",
                                          "validator.service")
  OnlyApp = """systemd.systemUnit {
  name = "app.service"
  content = "[Service]
ExecStart=/bin/true
"
  stateDirectories = ["carry:/var/lib/app"]
}
"""

proc confined(name, extra: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Service]\n" &
    "ProtectSystem=strict\n" & extra & "ExecStart=/bin/true\n\"\n}\n"

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
    check pendingCarriedState(src / "out", dst).len == 1
    expect StateSetError:
      discard restoreStateSet(src / "out", running("app.service"), root = dst)
    check not dirExists(dst / "var/lib/app")
    check restoreStateSet(src / "out", stopped(), root = dst) == @["/var/lib/app"]
    check treeDigest(dst / "var/lib/app") == treeDigest(src / "var/lib/app")
    check pendingCarriedState(src / "out", dst).len == 0
    # The receipt is tied to the root it was restored under: the live
    # host ("/") still has the state pending.
    check pendingCarriedState(src / "out", "/").len == 1
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
    check pendingCarriedState(src / "out", d2).len == 1

  test "an apply waits for carried state: refused until it is restored":
    let src = fresh("pend-src")
    populate(src)
    let p = parseSystemProfile(Profile)
    discard backupStateSet(p, src / "out", "h1", stopped(), hold = false,
                           root = src)
    let dst = fresh("pend-dst")
    let why = carriedStateRefusal(p, src / "out", dst)
    check why.startsWith("ECarriedStatePending")
    check "/var/lib/app (systemUnit:app.service" in why
    # A unit confined to paths of its own does not reach the set.
    check carriedStateRefusal(parseSystemProfile(confined("other.service",
      "ReadWritePaths=/var/lib/other\n")), src / "out", dst) == ""
    # ... one whose paths reach it does, whatever its name.
    for extra in ["ReadWritePaths=/var/lib/app\n", "ReadWritePaths=/var/lib\n",
                  "StateDirectory=app\n", "WorkingDirectory=/var/lib/app/db\n",
                  "BindPaths=/var/lib/app:/data\n",
                  "ReadWritePaths=%S/app\n"]:
      checkpoint extra
      check carriedStateRefusal(parseSystemProfile(confined("x.service",
        extra)), src / "out", dst).startsWith("ECarriedStatePending")
    # No manifest at all: nothing pending.
    check carriedStateRefusal(p, fresh("no-manifest"), dst) == ""
    # An unreadable manifest refuses (fail closed).
    let broken = fresh("broken")
    writeFile(broken / ManifestFileName, "{")
    check carriedStateRefusal(p, broken, dst).len > 0
    discard restoreStateSet(src / "out", stopped(), root = dst)
    check carriedStateRefusal(p, src / "out", dst) == ""
    # A restore under another root does not clear the wait here.
    check carriedStateRefusal(p, src / "out", fresh("pend-live")).
      startsWith("ECarriedStatePending")
    # Nor does a receipt whose directory was since replaced (same path,
    # another directory): only the restored one, or the manifest's tree.
    removeDir(dst / "var/lib/app")
    createDir(dst / "var/lib/app")
    check carriedStateRefusal(p, src / "out", dst).
      startsWith("ECarriedStatePending")

  test "a renamed unit that keeps the carried directory is held up":
    let src = fresh("ren-src")
    createDir(src / "var/lib/ethereum/validator")
    writeFile(src / "var/lib/ethereum/validator/validator.db", "history")
    discard backupStateSet(parseSystemProfile(OldValidator), src / "out", "h",
                           stopped(), hold = false, root = src)
    let dst = fresh("ren-dst")
    check carriedStateRefusal(parseSystemProfile(OldValidator), src / "out",
      dst).startsWith("ECarriedStatePending")
    check carriedStateRefusal(parseSystemProfile(RenamedValidator),
      src / "out", dst).startsWith("ECarriedStatePending")

  test "nothing is applied while a backup holds the host":
    let r = fresh("held")
    let p = parseSystemProfile(confined("other.service", ""))
    check carriedStateRefusal(p, fresh("held-none"), r) == ""
    createDir(r / "etc/systemd/system/app.service.d")
    writeFile(r / "etc/systemd/system/app.service.d" / HoldDropInName, "x")
    check heldUnits(r) == @["app.service"]
    let why = carriedStateRefusal(p, fresh("held-none2"), r)
    check why.startsWith("ECarriedStatePending") and "app.service" in why

  test "the add-on's apply refuses first, before anything else":
    let src = fresh("aa-src")
    populate(src)
    let p = parseSystemProfile(Profile)
    discard backupStateSet(p, src / "out", "h1", stopped(), hold = false,
                           root = src)
    let dst = fresh("aa-dst")
    let state = fresh("aa-state")
    var why = ""
    try:
      discard runAddonApply(AddonApplyOptions(stateDir: state,
        hostIdentity: "h", userProfileText: OnlyApp.replace(
          "  stateDirectories", "  floorExceptions = [\"serviceFloor: a " &
          "fixture\"]\n  stateDirectories"),
        carriedStateDir: src / "out", carriedStateRoot: dst))
    except AddonApplyError as e:
      why = e.msg
    check why.startsWith("ECarriedStatePending")
    var written = 0
    for _ in walkDirRec(state): inc written
    check written == 0

  test "a stored generation is read under its own rules before the refusal":
    # A revert or rollback target is a stored generation: one installed
    # before the floor names no hardening and runs /bin/true, which today's
    # floor default refuses. The carried-state check reads it the way the
    # switch does (``parseStoredUserProfile``), so it reaches its own
    # refusal instead of throwing on the floor. Red under the
    # ``stored-profile-floored`` build (stored generations parsed with the
    # floor).
    let src = fresh("st-src")
    populate(src)
    discard backupStateSet(parseSystemProfile(Profile), src / "out", "h1",
                           stopped(), hold = false, root = src)
    let dst = fresh("st-dst")
    let state = fresh("st-state")
    var why = ""
    try:
      discard runAddonApply(AddonApplyOptions(stateDir: state,
        hostIdentity: "h", userProfileText: OnlyApp, storedTarget: true,
        carriedStateDir: src / "out", carriedStateRoot: dst))
    except AddonApplyError as e:
      why = e.msg
    except CatchableError as e:
      why = "not the carried-state refusal: " & e.msg
    check why.startsWith("ECarriedStatePending")
    var written = 0
    for _ in walkDirRec(state): inc written
    check written == 0

  test "carried owners must keep their ids in the profile that uses them":
    let src = fresh("ids-src")
    createDir(src / "var/lib/ethereum/validator")
    writeFile(src / "var/lib/ethereum/validator/validator.db", "history")
    createDir(src / "etc")
    let me = $getuid()
    let grp = $getgid()
    writeFile(src / "etc/passwd", "eth-validator:x:" & me & ":" & grp &
      "::/:/usr/sbin/nologin\n")
    writeFile(src / "etc/group", "eth-validator:x:" & grp & ":\n")
    discard backupStateSet(parseSystemProfile(OldValidator), src / "out", "h",
                           stopped(), hold = false, root = src)
    let dst = fresh("ids-dst")
    discard restoreStateSet(src / "out", stopped(), root = dst)
    proc withAccount(id: string): SystemProfile =
      parseSystemProfile(OldValidator & "\nlinux.sysusersEntry {\n" &
        "  name = \"eth-validator\"\n" &
        (if id.len > 0: "  id = \"" & id & "\"\n" else: "") & "}\n")
    # Pinned to the source's id (users and groups share it here): fine.
    if me == grp:
      check carriedStateRefusal(withAccount(me), src / "out", dst) == ""
    # Created with a dynamic id: its id would differ, refused.
    check "without a pinned id" in
      carriedStateRefusal(withAccount(""), src / "out", dst)
    # Pinned to another id: refused.
    check "pinned to" in carriedStateRefusal(
      withAccount($(getuid().int + 7)), src / "out", dst)
    # The live account of that name has another id (a target whose
    # dynamic ids differ): refused.
    createDir(dst / "etc")
    writeFile(dst / "etc/passwd", "eth-validator:x:" & $(getuid().int + 3) &
      ":" & grp & "::/:/bin/sh\n")
    check " here but owns " in
      carriedStateRefusal(withAccount(me), src / "out", dst)

  test "hard links are refused, not carried as copies":
    let src = fresh("hl-src")
    createDir(src / "var/lib/ethereum/validator")
    writeFile(src / "var/lib/ethereum/validator/a", "x")
    check link(cstring(src / "var/lib/ethereum/validator/a"),
               cstring(src / "var/lib/ethereum/validator/b")) == 0
    var why = ""
    try:
      discard backupStateSet(parseSystemProfile(OldValidator), src / "out",
                             "h", stopped(), hold = false, root = src)
    except StateSetError as e:
      why = e.msg
    check "hard links" in why

  test "a retried restore removes a dead restore's staging directory":
    let src = fresh("st-src")
    populate(src)
    discard backupStateSet(parseSystemProfile(Profile), src / "out", "h1",
                           stopped(), hold = false, root = src)
    let dst = fresh("st-dst")
    createDir(dst / "var/lib/.repro-restore-app-99999/junk")
    discard restoreStateSet(src / "out", stopped(), root = dst)
    check not dirExists(dst / "var/lib/.repro-restore-app-99999")

  test "a sparse file comes back sparse":
    let src = fresh("sp-src")
    createDir(src / "var/lib/app")
    block:
      var f = open(src / "var/lib/app/sparse", fmWrite)
      f.write("head")
      f.setFilePos(64 * 1024 * 64)
      f.write("tail")
      f.close()
    discard backupStateSet(parseSystemProfile(OnlyApp), src / "out", "h",
                           stopped(), hold = false, root = src)
    # Restored onto tmpfs, which allocates every byte written (a file
    # system that compresses, ZFS here, turns written zeros into holes
    # itself and could not tell a sparse restore from a dense one).
    let dst = (if dirExists("/dev/shm"): "/dev/shm" else: getTempDir()) /
      ("t_addon_state_sets-sparse-" & $getpid())
    removeDir(dst)
    createDir(dst)
    defer: removeDir(dst)
    discard restoreStateSet(src / "out", stopped(), root = dst)
    var st: Stat
    check stat(cstring(dst / "var/lib/app/sparse"), st) == 0
    check st.st_size == 64 * 1024 * 64 + 4
    check st.st_blocks * 512 < 1024 * 1024
    check readFile(dst / "var/lib/app/sparse") ==
      readFile(src / "var/lib/app/sparse")

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

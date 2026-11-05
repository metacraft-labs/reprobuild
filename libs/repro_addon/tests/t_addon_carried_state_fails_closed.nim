## Carried state fails closed (ReproOS Add-On Mode §11.1; the A13 review,
## round 2): what the apply's wait and the boot-time restore decide when
## the evidence is incomplete.
##
## - **The receipt names one directory, not its inode.** A directory removed
##   and made again can get the inode just freed (ext4 does; the review
##   reproduced it on debian-13), so the receipt also binds the creation time
##   and the inode generation where the file system keeps them, and is not
##   trusted when neither can be compared: the live digest decides. Tested
##   without relying on the inode changing: the receipt is rewritten to the
##   live device and inode with another creation time or generation.
## - **Reach follows what a unit can run and start.** A "+"/"!" command or
##   ``PermissionsStartOnly=`` runs outside the sandbox; a
##   ``collision = "dropIn"`` unit sits over a file the profile does not
##   have; a unit (a timer, a target, a path, a service) that activates one
##   the profile does not define reaches what that one reaches. Each counts
##   as reaching the carried directory.
## - **The boot path requires the restore.** ``installRestoreUnit`` links
##   the restore unit into every carried unit's ``.requires/`` (not a
##   drop-in: those are the generation's), and a
##   restore at a later boot leaves alone a directory its receipt still
##   identifies (the service has changed it since).
## - **A backup excludes applies.** It takes the host apply lock, and checks
##   the units again after the hold is written.
##
## Falsifying mutations (``scripts/run_addon_unit_mutation.sh
## t_addon_carried_state_fails_closed <mutation>``), each red here:
## ``receipt-trusts-inode``, ``reach-ignores-privileged-commands``,
## ``reach-dropin-judged-alone``, ``reach-trigger-units-reach-nothing``,
## ``restore-not-required-by-units``, ``backup-without-host-lock``,
## ``apply-ignores-hold`` (the floored unit under a hold).
##
## *Mocking.* The unit liveness (``AlivenessFn``), as in
## ``t_addon_state_sets``: a unit test has no systemd unit whose cgroup the
## production check could read. The hold is off (``hold = false``): writing
## it needs root and a running systemd (the conversion gate runs it). The
## host apply lock is the real lock, at a test path (``REPRO_HOST_APPLY_LOCK``),
## held by a real second process (``flock``).

import std/[json, os, osproc, strutils, tables, unittest]

import repro_core/host_apply_lock

import repro_infra
from repro_test_support import testCaseScratchSlug
import repro_addon/[addon_apply, adoption_cli, state_sets, transitions]

const
  Validator = """systemd.systemUnit {
  name = "eth-validator.service"
  content = "[Service]
ProtectSystem=strict
ReadWritePaths=/var/lib/ethereum/validator
ExecStart=/bin/true
"
  stateDirectories = ["carry:/var/lib/ethereum/validator"]
}
"""

proc stopped(): AlivenessFn =
  result = proc (u: string): UnitAliveness = uaEmpty

var scratch = getTempDir() / ("t_addon_carried_state_fails_closed" &
                              testCaseScratchSlug())

proc fresh(name: string): string =
  result = scratch / name
  removeDir(result)
  createDir(result)

proc unit(name, body: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" & body &
    "\"\n" & extra & "}\n"

var carried = ""

proc carriedDir(): string =
  ## A backup of the validator's directory, made once.
  if carried.len > 0: return carried
  let src = fresh("src")
  createDir(src / "var/lib/ethereum/validator")
  writeFile(src / "var/lib/ethereum/validator/validator.db", "history\n")
  discard backupStateSet(parseSystemProfile(Validator), src / "out", "h",
                         stopped(), hold = false, root = src)
  carried = src / "out"
  carried

proc refusal(text: string; root: string): string =
  carriedStateRefusal(parseSystemProfile(text), carriedDir(), root)

suite "carried state fails closed":
  test "a directory replaced in place is pending, whatever its inode":
    let dst = fresh("dst-inode")
    check restoreStateSet(carriedDir(), stopped(), root = dst) ==
      @["/var/lib/ethereum/validator"]
    let v = dst / "var/lib/ethereum/validator"
    # The service used it: its tree is no longer the manifest's, and the
    # receipt alone says it is the restored directory.
    writeFile(v / "validator.db", "history and more\n")
    let live = dirIdentity(v)
    let canTell = live.haveBtime or live.haveGen
    checkpoint "creation time " & $live.haveBtime & ", generation " &
      $live.haveGen
    # With a discriminator the receipt is trusted; without one it is not
    # (fail closed: the live digest decides, and it differs).
    check (pendingCarriedState(carriedDir(), dst).len == 0) == canTell
    # A replacement that got the same device and inode: rewrite the
    # receipt as if the restored directory had had another creation time
    # and generation. It must not count as the restored one.
    var r = readReceipt(carriedDir())
    var id = r["/var/lib/ethereum/validator"].id
    check id.dev == live.dev and id.ino == live.ino
    id.haveBtime = true
    id.btimeSec = live.btimeSec - 1000
    id.haveGen = true
    id.gen = live.gen + 1
    r["/var/lib/ethereum/validator"].id = id
    writeReceipt(carriedDir(), r)
    check pendingCarriedState(carriedDir(), dst).len == 1
    check refusal(Validator, dst).startsWith("ECarriedStatePending")
    # A receipt of an older build (device and inode only) is not trusted
    # either.
    id.haveBtime = false
    id.haveGen = false
    r["/var/lib/ethereum/validator"].id = id
    writeReceipt(carriedDir(), r)
    check pendingCarriedState(carriedDir(), dst).len == 1
    removeFile(receiptPath(carriedDir()))

  test "the identity compares only what both sides have, and needs one":
    let a = DirIdentity(dev: 1, ino: 2, haveBtime: true, btimeSec: 5,
                        btimeNsec: 6, haveGen: true, gen: 7)
    check sameDirectory(a, a)
    var b = a
    b.btimeNsec = 7
    check not sameDirectory(a, b)
    b = a
    b.gen = 8
    check not sameDirectory(a, b)
    b = a
    b.haveGen = false                 # a file system with no generation
    check sameDirectory(a, b)
    b.haveBtime = false               # ... and no creation time
    check not sameDirectory(a, b)
    b = a
    b.ino = 3
    check not sameDirectory(a, b)
    check not sameDirectory(DirIdentity(dev: -1, ino: -1), a)

  test "a directory removed and made again is never the same directory":
    # On the file system the test runs on, whatever it is: a new directory
    # that got a freed inode (ext4 hands them out again) must still be told
    # apart, and on a file system with no creation time and no generation
    # nothing is ever "the same" (fail closed). Ported from the A13 review's
    # round-3 probe.
    let base = fresh("identity")
    var before: seq[DirIdentity]
    for i in 0 ..< 200:
      createDir(base / $i)
      before.add(dirIdentity(base / $i))
    let d = base / "one"
    createDir(d)
    let a = dirIdentity(d)
    removeDir(d)
    createDir(d)
    check not sameDirectory(a, dirIdentity(d))
    for i in 0 ..< 200: removeDir(base / $i)
    var reused, judgedSame = 0
    for i in 0 ..< 200:
      createDir(base / ("n" & $i))
      let b = dirIdentity(base / ("n" & $i))
      for x in before:
        if x.dev == b.dev and x.ino == b.ino:
          inc reused
          if sameDirectory(x, b): inc judgedSame
    checkpoint "inodes reused: " & $reused
    check judgedSame == 0

  test "a later restore leaves a directory its receipt still identifies":
    let dst = fresh("dst-reboot")
    discard restoreStateSet(carriedDir(), stopped(), root = dst)
    let v = dst / "var/lib/ethereum/validator"
    writeFile(v / "validator.db", "history and new signatures\n")
    if dirIdentity(v).haveBtime or dirIdentity(v).haveGen:
      # The next boot's restore: nothing to restore, nothing refused.
      check restoreStateSet(carriedDir(), stopped(), root = dst).len == 0
      check readFile(v / "validator.db") == "history and new signatures\n"
    else:
      # No discriminator: the changed directory cannot be told from a
      # replacement, and the restore refuses (fail closed).
      expect StateSetError:
        discard restoreStateSet(carriedDir(), stopped(), root = dst)
    removeFile(receiptPath(carriedDir()))

  test "a command outside the sandbox reaches everything":
    let dst = fresh("dst-reach")
    for body in [
        "[Service]\nProtectSystem=strict\nUser=app\nReadWritePaths=/var/lib/other\n" &
          "ExecStartPre=+/bin/sh -c 'touch /var/lib/ethereum/validator/x'\n" &
          "ExecStart=/bin/true\n",
        "[Service]\nProtectSystem=strict\nUser=app\n" &
          "ExecStartPost=+/usr/bin/rm -rf /var/lib/ethereum/validator\n" &
          "ExecStart=/bin/true\n",
        "[Service]\nProtectSystem=strict\nUser=app\nExecStart=!/bin/true\n",
        "[Service]\nProtectSystem=strict\nUser=app\nExecStart=-+/bin/true\n",
        "[Service]\nProtectSystem=strict\nUser=app\nPermissionsStartOnly=yes\n" &
          "ExecStart=/bin/true\n"]:
      checkpoint body
      check refusal(unit("other.service", body), dst).
        startsWith("ECarriedStatePending")
    # The same unit without the privileged command stays out of it.
    check refusal(unit("other.service", "[Service]\nProtectSystem=strict\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStartPre=-/bin/true\n" &
      "ExecStart=/bin/true\n"), dst) == ""

  test "a drop-in over a distribution unit reaches everything":
    check refusal(unit("pkg-validator.service", "[Service]\n" &
      "ProtectSystem=strict\nUser=app\nExecStart=\nExecStart=/bin/true\n",
      "  collision = \"dropIn\"\n"), fresh("dst-dropin")).
      startsWith("ECarriedStatePending")

  test "a unit that starts one the profile does not define reaches everything":
    let dst = fresh("dst-trigger")
    for (name, body) in [
        ("x.timer", "[Timer]\nOnBootSec=1\nUnit=lighthouse-vc.service\n"),
        ("lighthouse-vc.timer", "[Timer]\nOnBootSec=1\n"),
        ("x.path", "[Path]\nPathExists=/run/x\nUnit=lighthouse-vc.service\n"),
        ("x.target", "[Unit]\nWants=lighthouse-vc.service\n"),
        ("y.target", "[Unit]\nRequires=lighthouse-vc.service\n"),
        ("z.service", "[Unit]\nOnFailure=lighthouse-vc.service\n" &
          "[Service]\nProtectSystem=strict\nUser=app\nExecStart=/bin/true\n"),
        ("w.service", "[Unit]\nWants=lighthouse-vc.service\n[Service]\n" &
          "ProtectSystem=strict\nUser=app\nExecStart=/bin/true\n")]:
      checkpoint name
      check refusal(unit(name, body), dst).startsWith("ECarriedStatePending")
    # A timer of a service the profile defines (and confines elsewhere) is
    # judged by that service, and ordering alone starts nothing.
    let svc = unit("other.service", "[Service]\nProtectSystem=strict\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    check refusal(svc & unit("other.timer", "[Timer]\nOnBootSec=1\n"), dst) == ""
    check refusal(svc & unit("t.target", "[Unit]\nWants=other.service\n" &
      "After=lighthouse-vc.service\n"), dst) == ""

  test "the restore unit is required by every carried unit":
    let root = fresh("root-install")
    let units = installRestoreUnit(carriedDir(), "/usr/bin/repro", root)
    check units == @["eth-validator.service"]
    let d = root / "etc/systemd/system"
    check fileExists(d / RestoreUnitName)
    check expandSymlink(d / "sysinit.target.wants" / RestoreUnitName) ==
      "/etc/systemd/system/" & RestoreUnitName
    # Owned by the carried unit (a drop-in, not a link a disable or a
    # preset of the restore unit removes), with the ordering in it.
    let dropIn = d / "eth-validator.service.d" / RestoreRequiredDropIn
    check fileExists(dropIn)
    check ("Requires=" & RestoreUnitName) in readFile(dropIn)
    check ("After=" & RestoreUnitName) in readFile(dropIn)
    check not dirExists(d / "eth-validator.service.requires")
    # ... and the restore unit orders itself before each carried unit by
    # name, for one without default dependencies.
    let unitText = readFile(d / RestoreUnitName)
    check "Before=sysinit.target shutdown.target eth-validator.service" in unitText
    check "ConditionPathExists" notin unitText
    # The installation is recorded beside the carried directory.
    check fileExists(root / installedMarkerPath(carriedDir()))

  test "a manifest missing where carried state was installed refuses":
    let src = fresh("src-missing")
    createDir(src / "var/lib/ethereum/validator")
    writeFile(src / "var/lib/ethereum/validator/validator.db", "history\n")
    let p = parseSystemProfile(Validator)
    discard backupStateSet(p, src / "carried", "h", stopped(), hold = false,
                           root = src)
    let dir = src / "carried"
    # Not installed: no manifest means no carried state.
    removeFile(dir / ManifestFileName)
    check carriedStateRefusal(p, dir, fresh("dst-missing")) == ""
    # Installed, then the manifest (or the whole directory) went: refused.
    writeFile(installedMarkerPath(dir), dir & "\n")
    check carriedStateRefusal(p, dir, fresh("dst-missing2")).
      startsWith("ECarriedStatePending")
    removeDir(dir)
    check carriedStateRefusal(p, dir, fresh("dst-missing3")).
      startsWith("ECarriedStatePending")

  test "install-unit refuses a carried directory other than the default":
    check runStateCli(@["install-unit", "--from", "/srv/elsewhere",
                        "--root", fresh("root-from")]) == 2

  test "under a hold a floored unit is refused for the carried state first":
    # A floored unit (one named exception, not a waiver: the rest of the
    # floor applies): the add-on's effective-unit check
    # (spec §10.1) refuses any drop-in the generation did not write, the
    # hold among them, but only at the switch's step 6. The carried-state
    # refusal comes before anything is looked at or written, so a host
    # under a backup's hold always answers ECarriedStatePending.
    let r = fresh("held-floored")
    createDir(r / "etc/systemd/system/eth-validator.service.d")
    writeFile(r / "etc/systemd/system/eth-validator.service.d" /
              HoldDropInName, "x")
    let state = fresh("held-floored-state")
    var why = ""
    try:
      discard runAddonApply(AddonApplyOptions(stateDir: state,
        hostIdentity: "h", userProfileText: Validator.replace(
          "  stateDirectories", "  floorExceptions = [\"NoExecPaths: the " &
          "test runs /bin/true\"]\n  stateDirectories"),
        carriedStateDir: fresh("held-floored-none"), carriedStateRoot: r))
    except AddonApplyError as e:
      why = e.msg
    except CatchableError as e:
      why = "other: " & e.msg
    checkpoint "refusal: " & why
    check why.startsWith("ECarriedStatePending")
    check "EAddOnFloorNotEffective" notin why
    var written = 0
    for _ in walkDirRec(state): inc written
    check written == 0

  test "a backup takes the host apply lock and checks the units again":
    let src = fresh("src-lock")
    createDir(src / "var/lib/ethereum/validator")
    writeFile(src / "var/lib/ethereum/validator/validator.db", "history\n")
    let p = parseSystemProfile(Validator)
    let lock = scratch / "host-apply.lock"
    putEnv("REPRO_HOST_APPLY_LOCK", lock)
    putEnv("REPRO_HOST_APPLY_LOCK_WAIT_SECONDS", "0")
    defer:
      delEnv("REPRO_HOST_APPLY_LOCK")
      delEnv("REPRO_HOST_APPLY_LOCK_WAIT_SECONDS")
    # Another process holds the lock (an apply in progress): the backup
    # refuses and writes nothing.
    let holder = startProcess("flock", args = [lock, "sleep", "30"],
                              options = {poUsePath})
    var held = false
    for i in 0 ..< 50:
      if execCmdEx("flock -n " & quoteShell(lock) & " true").exitCode != 0:
        held = true
        break
      sleep(100)
    check held
    expect StateSetError:
      discard backupStateSet(p, src / "out1", "h", stopped(), hold = false,
                             root = src)
    check not fileExists(src / "out1" / ManifestFileName)
    holder.terminate()
    discard holder.waitForExit()
    holder.close()
    # A unit that starts between the first check and the hold is caught by
    # the second, and the backup leaves nothing behind.
    var calls = 0
    let startsLater: AlivenessFn = proc (u: string): UnitAliveness =
      inc calls
      if calls > 1: uaPopulated else: uaEmpty
    expect StateSetError:
      discard backupStateSet(p, src / "out2", "h", startsLater, hold = false,
                             root = src)
    check not dirExists(src / "out2")

suite "reach is default-deny":
  proc refused(text: string): bool =
    var why = ""
    try: why = refusal(text, fresh("dst-dd"))
    except CatchableError as e: why = "PARSE: " & e.msg
    checkpoint "refusal: " & why
    why.startsWith("ECarriedStatePending")

  proc confinedWith(name, extra: string): string =
    unit(name, "[Service]\nProtectSystem=strict\nUser=app\n" & extra &
      "ExecStart=/bin/true\n")

  test "a path is compared as systemd resolves it":
    for extra in ["ReadWritePaths=/var/lib//ethereum/validator\n",
                  "ReadWritePaths=/var/lib/./ethereum/validator\n",
                  "ReadWritePaths=/var/lib/ethereum/validator/\n",
                  "ReadWritePaths=-/var/lib/ethereum/validator\n",
                  "ReadWritePaths=\"/var/lib/ethereum/validator\"\n",
                  "ReadWritePaths=/srv/a '/var/lib/ethereum//validator'\n",
                  "ReadWriteDirectories=/var/lib/ethereum/validator\n",
                  "BindPaths=-/var/lib/ethereum/validator:/data\n",
                  "BindPaths=/srv/x:/var/lib//ethereum/validator\n",
                  "TemporaryFileSystem=/var/lib/ethereum/validator:ro\n",
                  "StateDirectory=ethereum//validator\n",
                  "StandardOutput=append:/var/lib//ethereum/validator/log\n"]:
      checkpoint extra
      check refused(confinedWith("p.service", extra))
    # A form not resolved here reaches everything.
    for extra in ["ReadWritePaths=/var/lib/../lib/ethereum/validator\n",
                  "ReadWritePaths=%S/ethereum\n",
                  "ReadWritePaths=/srv/a\\x20b\n",
                  "ReadWritePaths='/srv/unterminated\n"]:
      checkpoint extra
      check refused(confinedWith("p2.service", extra))
    # A confined unit elsewhere stays out of it.
    check not refused(confinedWith("p3.service",
      "ReadWritePaths=/var/lib//other/./x\nReadOnlyPaths=/var/lib/ethereum\n"))

  test "a key, section or command prefix not understood reaches everything":
    for extra in ["ExecStartPre=|+rm -rf /var/lib/ethereum/validator\n",
                  "ExecStartPre=+|/bin/true\n",
                  "ExecStartPre=@-!/bin/true\n",
                  "ExecStartPre=*/bin/true\n",
                  "SomeFutureSetting=yes\n",
                  "Sockets=ssh.socket\n",
                  "SupplementaryGroups=disk\n",
                  "RootDirectory=/srv/root\n",
                  "Group=root\n",
                  "User=\n"]:
      checkpoint extra
      check refused(confinedWith("k.service", extra))
    check refused(unit("k2.service", "[Service]\nProtectSystem=strict\n" &
      "User=app\nExecStart=/bin/true\n[X-Vendor]\nFoo=bar\n"))

  test "a root service under ProtectSystem=strict reaches everything":
    check refused(unit("r.service", "[Service]\nProtectSystem=strict\n" &
      "ExecStart=/bin/sh -c 'echo x > /proc/1/root/var/lib/ethereum/validator/x'\n"))
    check refused(unit("r2.service", "[Service]\nProtectSystem=strict\n" &
      "User=root\nExecStart=/bin/true\n"))

  test "drop-ins apply in file-name order, not profile order":
    check refused(unit("o5.service", "[Service]\nUser=app\n" &
        "ExecStart=/bin/sh -c 'rm -rf /var/lib/ethereum/validator'\n") &
      "systemd.systemDropIn {\n  unit = \"o5.service\"\n  name = \"90-unconfine\"\n" &
        "  content = \"[Service]\nProtectSystem=no\n\"\n}\n" &
      "systemd.systemDropIn {\n  unit = \"o5.service\"\n  name = \"10-confine\"\n" &
        "  content = \"[Service]\nProtectSystem=strict\n\"\n}\n")

  test "every resource kind is judged":
    for text in [
        "linux.tmpfilesRule {\n  name = \"zap.conf\"\n  content = \"R /var/lib/ethereum/validator\"\n}\n",
        "linux.tmpfilesRule {\n  name = \"zap2.conf\"\n  content = \"D /var/lib//ethereum - - - -\"\n}\n",
        "linux.tmpfilesRule {\n  name = \"zap3.conf\"\n  content = \"e /var/lib/%n - - - 1d\"\n}\n",
        "fs.systemFile {\n  path = \"/var/lib/ethereum/validator/slashing.db\"\n  content = \"x\"\n}\n",
        "fs.systemDirectory {\n  path = \"/var/lib/ethereum/validator\"\n}\n",
        "systemd.systemTimer {\n  name = \"apt-daily.timer\"\n  content = \"[Timer]\nOnActiveSec=1\n\"\n}\n",
        "passwd.user {\n  name = \"x\"\n  home = \"/var/lib/ethereum/validator\"\n}\n",
        "systemd.unitState {\n  name = \"lighthouse-vc.service\"\n  running = false\n}\n",
        "linux.udevRule {\n  name = \"99-x.rules\"\n  content = \"x\"\n}\n"]:
      checkpoint text
      check refused(text)
    # A tmpfiles rule and a file elsewhere stay out of it.
    check not refused("linux.tmpfilesRule {\n  name = \"ok.conf\"\n" &
      "  content = \"d /var/lib/other 0700 root root -\"\n}\n")
    check not refused("fs.systemFile {\n  path = \"/etc/other.conf\"\n" &
      "  content = \"x\"\n}\n")

  test "an apply decides carried state again under the host lock":
    # The lock is held by another process (a backup, say) which writes its
    # hold before it lets go: the apply, waiting for the lock, must see the
    # hold once it has it.
    let r = fresh("lock-root")
    let lock = scratch / "host-apply-2.lock"
    putEnv("REPRO_HOST_APPLY_LOCK", lock)
    putEnv("REPRO_HOST_APPLY_LOCK_WAIT_SECONDS", "60")
    defer:
      delEnv("REPRO_HOST_APPLY_LOCK")
      delEnv("REPRO_HOST_APPLY_LOCK_WAIT_SECONDS")
    let holdDir = r / "etc/systemd/system/eth-validator.service.d"
    let holder = startProcess("flock", args = [lock, "sh", "-c",
      "sleep 2; mkdir -p " & quoteShell(holdDir) & " && echo x > " &
      quoteShell(holdDir / HoldDropInName)], options = {poUsePath})
    sleep(500)
    var why = ""
    try:
      var l = hostLockWithCarriedRecheck(AddonApplyOptions(stateDir:
        fresh("lock-state"), hostIdentity: "h", userProfileText: "",
        carriedStateDir: fresh("lock-none"), carriedStateRoot: r),
        fresh("lock-state2"))
      l.release()
    except AddonApplyError as e:
      why = e.msg
    discard holder.waitForExit()
    holder.close()
    check why.startsWith("ECarriedStatePending")

removeDir(scratch)

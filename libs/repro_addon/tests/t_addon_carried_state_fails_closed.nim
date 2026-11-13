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
## ``apply-ignores-hold`` (the floored unit under a hold); round 4:
## ``account-as-written`` (F1-F2b), ``reach-timer-dropins-unread`` (F3,
## F3b), ``reach-host-dropins-ignored`` (each host source),
## ``reach-path-unit-paths-ignored`` (F4) and
## ``restore-requirement-by-manifest-only`` (F6); round 6:
## ``unit-lines-continue-as-text`` (R7-1, R7-1b, R7-2),
## ``exec-first-command-only`` (R7-3), ``alias-chain-first-link-only``
## (R7-4), ``dependency-links-unread`` (R7-5, R7-7),
## ``requirement-name-not-reserved`` (R7-6), ``privileged-daemons-unread``
## (decision 58), ``restore-requirement-skips-closure`` (decision 60);
## round 7: ``narrowed-live-set`` (a switch that writes no unit file),
## ``boot-closure-reads-generation-dropins`` (P60-2),
## ``polkit-subject-rebind-trusted`` (P58-1, P58-2 and the other binding
## forms), ``reissue-skips-targets`` and ``reissue-skips-sockets``
## (decision 79, each on its own case).
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
import repro_infra/systemd_syntax
from repro_test_support import testCaseScratchSlug
import repro_elevation
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
  ## A scratch root with the accounts the fixtures' units name: since the
  ## reach analysis resolves a unit's account (``service_account``), an
  ## account the host does not have reaches everything.
  result = scratch / name
  removeDir(result)
  createDir(result / "etc")
  writeFile(result / "etc/passwd", "root:x:0:0::/root:/bin/sh\n" &
    "app:x:1001:1001::/:/usr/sbin/nologin\n" &
    "validator:x:1002:1002::/:/usr/sbin/nologin\n")
  writeFile(result / "etc/group", "root:x:0:\napp:x:1001:\nvalidator:x:1002:\n")
  # Every NSS source the lookup reads, so it is authoritative: a name it
  # does not know does not exist (``service_account.nssCovered``).
  writeFile(result / "etc/nsswitch.conf", "passwd: files systemd\n" &
    "group: files systemd\n")

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
        "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nReadWritePaths=/var/lib/other\n" &
          "ExecStartPre=+/bin/sh -c 'touch /var/lib/ethereum/validator/x'\n" &
          "ExecStart=/bin/true\n",
        "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
          "ExecStartPost=+/usr/bin/rm -rf /var/lib/ethereum/validator\n" &
          "ExecStart=/bin/true\n",
        "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=!/bin/true\n",
        "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=-+/bin/true\n",
        "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nPermissionsStartOnly=yes\n" &
          "ExecStart=/bin/true\n"]:
      checkpoint body
      check refusal(unit("other.service", body), dst).
        startsWith("ECarriedStatePending")
    # The same unit without the privileged command stays out of it.
    check refusal(unit("other.service", "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStartPre=-/bin/true\n" &
      "ExecStart=/bin/true\n"), dst) == ""

  test "a drop-in over a distribution unit reaches everything":
    check refusal(unit("pkg-validator.service", "[Service]\n" &
      "ProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=\nExecStart=/bin/true\n",
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
          "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n"),
        ("w.service", "[Unit]\nWants=lighthouse-vc.service\n[Service]\n" &
          "ProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n")]:
      checkpoint name
      check refusal(unit(name, body), dst).startsWith("ECarriedStatePending")
    # A timer of a service the profile defines (and confines elsewhere) is
    # judged by that service, and ordering alone starts nothing.
    let svc = unit("other.service", "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    check refusal(svc & unit("other.timer", "[Timer]\nOnBootSec=1\n"), dst) == ""
    check refusal(svc & unit("t.target", "[Unit]\nWants=other.service\n" &
      "After=lighthouse-vc.service\n"), dst) == ""

  test "the restore unit is required by every carried unit":
    # ``install-unit --root R`` reads R's carried directory, as a conversion
    # preparing a target disk runs it (A13 review round 5, finding 8): the
    # manifest is under R only, none on this host.
    let root = fresh("root-install")
    let rooted = under(root, CarriedStateDir)
    createDir(rooted.parentDir)
    copyDir(carriedDir(), rooted)
    check runStateCli(@["install-unit", "--root", root]) == 0
    let units = installRestoreUnit(rooted, "/usr/bin/repro", root)
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
    check fileExists(installedMarkerPath(rooted))
    check not fileExists(root / installedMarkerPath(rooted))   # not rooted twice

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
    for f in walkDirRec(state):
      # The scratch root's account files (``fresh``) are the fixture's.
      if f notin [state / "etc/passwd", state / "etc/group",
                  state / "etc/nsswitch.conf"]: inc written
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
    unit(name, "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" & extra &
      "ExecStart=/bin/true\n")

  test "an optional (-) path reaches as the plain form does":
    # The gate's round-6 probes widen a unit to the carried directory with
    # ReadWritePaths=- (a missing path is ignored, so a probe a falsifier
    # lets in can run while the directory is pending): both forms are
    # refused for the carried path. Falsifier: optional-paths-ignored.
    check refused(confinedWith("o.service", "ReadWritePaths=/var/lib/ethereum/validator\n"))
    check refused(confinedWith("o.service", "ReadWritePaths=-/var/lib/ethereum/validator\n"))
    check refused(confinedWith("o.service", "BindPaths=-/var/lib/ethereum/validator\n"))

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


# ---------------------------------------------------------------------------
# A13 review round 4: the account systemd will use, every drop-in systemd
# reads, a path unit's paths, and the restore requirement derived from
# reach at every apply. Ported from the reviewer's probe
# (t_rev_a13r5_probe.nim, F1-F6), plus each host drop-in source.
# ---------------------------------------------------------------------------

proc pendingRefused(text: string; prepare: proc (root: string) = nil): bool =
  ## Whether an apply of ``text`` is refused while the validator's carried
  ## directory is pending, on a scratch host ``prepare`` may add files to.
  let root = fresh("dst-r4")
  if prepare != nil: prepare(root)
  var why = ""
  try: why = refusal(text, root)
  except CatchableError as e: why = "PARSE: " & e.msg
  checkpoint "refusal: " & why
  why.startsWith("ECarriedStatePending") or why.startsWith("PARSE")

proc confinedR(name, extra: string): string =
  unit(name, "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" & extra &
    "ExecStart=/bin/true\n")

proc hostFile(root, path, content: string) =
  createDir((root & path).parentDir)
  writeFile(root & path, content)

suite "reach judges the account systemd will use (round 4)":
  test "control: a confined unit of a non-root account elsewhere is let in":
    check not pendingRefused(confinedR("c0.service",
      "ReadWritePaths=/var/lib/other\n"))

  test "F1: DynamicUser=yes with User=root runs as root":
    check pendingRefused(unit("f1.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nUser=root\nExecStart=/bin/true\n"))

  test "F1b: DynamicUser=yes with Group=root holds gid 0":
    check pendingRefused(unit("f1b.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nUser=app\nGroup=root\nExecStart=/bin/true\n"))

  test "F2: User=%U is the system manager's uid, 0":
    check pendingRefused(unit("f2.service",
      "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=%U\nExecStart=/bin/true\n"))

  test "F2b: a template's User=%i names no account (DefaultInstance=root)":
    check pendingRefused(unit("f2b@.service",
      "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=%i\nExecStart=/bin/true\n" &
      "[Install]\nWantedBy=multi-user.target\nDefaultInstance=root\n"))

  test "a uid alias of root, and an account the host does not have, reach everything":
    check pendingRefused(confinedR("al.service", "ReadWritePaths=/var/lib/other\n"),
      proc (root: string) =
        writeFile(root / "etc/passwd", "root:x:0:0::/root:/bin/sh\n" &
          "app:x:0:0::/:/bin/sh\n"))
    check pendingRefused(unit("gh.service", "[Service]\nProtectSystem=strict\n" &
      "NoNewPrivileges=yes\nUser=ghost\nExecStart=/bin/true\n"))

  test "a dynamic user is confined without ProtectSystem=":
    check not pendingRefused(unit("dyn.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nUser=nosuchdyn\n" &
      "ExecStart=/bin/true\n"))

suite "reach reads every drop-in systemd applies (round 4)":
  test "F3: a profile drop-in retargets a profile timer at a distribution unit":
    check pendingRefused("systemd.systemTimer {\n  name = \"t3.timer\"\n" &
      "  content = \"[Timer]\nOnActiveSec=1\nUnit=c0.service\n\"\n}\n" &
      confinedR("c0.service", "") &
      "systemd.systemDropIn {\n  unit = \"t3.timer\"\n  name = \"20-retarget\"\n" &
      "  content = \"[Timer]\nUnit=apt-daily.service\n\"\n}\n")

  test "F3b: a profile timer's drop-in with a section not understood":
    check pendingRefused("systemd.systemTimer {\n  name = \"t4.timer\"\n" &
      "  content = \"[Timer]\nOnActiveSec=1\nUnit=c0.service\n\"\n}\n" &
      confinedR("c0.service", "") &
      "systemd.systemDropIn {\n  unit = \"t4.timer\"\n  name = \"20-x\"\n" &
      "  content = \"[X-Unknown]\nFoo=bar\n\"\n}\n")

  test "control: a profile timer on a confined profile service is let in":
    check not pendingRefused("systemd.systemTimer {\n  name = \"t5.timer\"\n" &
      "  content = \"[Timer]\nOnActiveSec=1\nUnit=c0.service\n\"\n}\n" &
      confinedR("c0.service", ""))

  const C0 = "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n"
  for (label, path, content) in [
      ("a type-wide service.d drop-in in /usr/lib",
       "/usr/lib/systemd/system/service.d/50-x.conf", "[Service]\nProtectSystem=no\n"),
      ("a dashed-prefix drop-in in /run",
       "/run/systemd/system/c0-.service.d/10-x.conf", "[Service]\nUser=root\n"),
      ("a host drop-in of the unit's own in /etc",
       "/etc/systemd/system/c0-x.service.d/10-foreign.conf",
       "[Service]\nExecStartPre=+/bin/true\n"),
      ("a generator's drop-in",
       "/run/systemd/generator/c0-x.service.d/x.conf", "[Service]\nProtectSystem=no\n"),
      ("a unit file in /run/systemd/transient, read before the generation's",
       "/run/systemd/transient/c0-x.service", C0)]:
    test "a host source is read: " & label:
      check not pendingRefused(confinedR("c0-x.service", ""))
      check pendingRefused(confinedR("c0-x.service", ""),
        proc (root: string) = hostFile(root, path, content))

  test "a host drop-in that keeps the unit confined is read and let in":
    check not pendingRefused(confinedR("c0-x.service", ""),
      proc (root: string) = hostFile(root,
        "/usr/lib/systemd/system/service.d/10-timeout-abort.conf",
        "[Service]\nTimeoutStopFailureMode=abort\n"))

  test "drop-ins of all sources apply in one file-name order":
    # The host's 90- unconfines; the profile's 50- confines: systemd reads
    # 50 then 90, so the unit is not confined.
    check pendingRefused(unit("o.service", "[Service]\nNoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n") &
      "systemd.systemDropIn {\n  unit = \"o.service\"\n  name = \"confine\"\n" &
      "  content = \"[Service]\nProtectSystem=strict\n\"\n}\n",
      proc (root: string) = hostFile(root,
        "/etc/systemd/system/o.service.d/90-unconfine.conf",
        "[Service]\nProtectSystem=no\n"))

  test "a 50-repro drop-in the profile no longer declares is read like any drop-in":
    # Round 4 skipped every 50-repro-*.conf as the generation's; systemd
    # loads any .conf there (A13 review round 5, finding 3).
    check pendingRefused(confinedR("c0-x.service", ""),
      proc (root: string) = hostFile(root,
        "/etc/systemd/system/c0-x.service.d/50-repro-old.conf",
        "[Service]\nProtectSystem=no\n"))

  test "a 50-repro drop-in the profile declares is judged by the profile's bytes":
    # The on-disk copy is the previous generation's; the profile's replaces it.
    check not pendingRefused(confinedR("c0-x.service", "") &
      "systemd.systemDropIn {\n  unit = \"c0-x.service\"\n  name = \"tune\"\n" &
      "  content = \"[Service]\nTimeoutStopSec=5\n\"\n}\n",
      proc (root: string) = hostFile(root,
        "/etc/systemd/system/c0-x.service.d/50-repro-tune.conf",
        "[Service]\nProtectSystem=no\n"))

suite "a path unit reaches the paths it watches (round 4)":
  test "F4: MakeDirectory= creates inside the carried directory":
    check pendingRefused(unit("f4.path",
      "[Path]\nDirectoryNotEmpty=/var/lib/ethereum/validator/spool\n" &
      "MakeDirectory=yes\nUnit=c0.service\n") & confinedR("c0.service", ""))

  test "a glob reaches the directory it is anchored in":
    check pendingRefused(unit("g.path",
      "[Path]\nPathExistsGlob=/var/lib/ethereum/validator/*.lock\n" &
      "Unit=c0.service\n") & confinedR("c0.service", ""))

  test "control: a path unit watching elsewhere is let in":
    check not pendingRefused(unit("e.path",
      "[Path]\nPathChanged=/var/lib/other/x\nUnit=c0.service\n") &
      confinedR("c0.service", ""))

suite "the restore requirement follows reach at every apply (round 4)":
  test "F6: a renamed unit reaching the restored directory requires the restore":
    let root = fresh("boot-r4")
    let d2 = scratch / "carried-r4"
    removeDir(d2)
    copyDir(carriedDir(), d2)
    discard restoreStateSet(d2, stopped(), root = root)
    let renamed = confinedR("validator2.service",
      "ReadWritePaths=/var/lib/ethereum/validator\n")
    let elsewhere = confinedR("other.service", "ReadWritePaths=/var/lib/other\n")
    # Restored: the apply lets it in.
    check refusal(renamed & elsewhere, root) == ""
    # Not installed (no install-unit marker): no requirement is added.
    check carriedRequirementUnits(parseSystemProfile(renamed), d2, root).len == 0
    writeFile(installedMarkerPath(d2), d2 & "\n")
    let units = carriedRequirementUnits(parseSystemProfile(renamed & elsewhere),
                                        d2, root)
    check units == @["validator2.service"]
    let text = withCarriedRequirements(renamed & elsewhere, d2, root)
    let p = parseSystemProfile(text)
    var found = false
    for r in p.resources:
      if r.kind == srkSystemdSystemDropIn and r.diUnit == "validator2.service":
        found = r.diName == RequirementDropInName and
          r.diContent == restoreRequirementText()
      check not (r.kind == srkSystemdSystemDropIn and r.diUnit == "other.service")
    check found
    check "Requires=repro-state-restore.service" in restoreRequirementText()
    check "After=repro-state-restore.service" in restoreRequirementText()
    # A unit reaching everything requires it too.
    check carriedRequirementUnits(parseSystemProfile(unit("r.service",
      "[Service]\nExecStart=/bin/true\n")), d2, root) == @["r.service"]
    # The generation's drop-in, once written, does not make the unit reach
    # everything at the next apply (it is the generation's own).
    hostFile(root, "/etc/systemd/system/validator2.service.d/50-repro-" &
      RequirementDropInName & ".conf", restoreRequirementText())
    check carriedRequirementUnits(parseSystemProfile(renamed & elsewhere),
                                  d2, root) == @["validator2.service"]


# ---------------------------------------------------------------------------
# A13 review round 5: values as systemd parses them, confinement under
# decision 54, the account under DynamicUser=, every name a unit loads
# under, the requirement on what a profile starts, a stored plan, and the
# live cross-check. Each case has a control that passes first (the round-4
# probe's control once went red only because accounts began to resolve).
# Ported from the reviewer's probe (t_rev_a13r6_probe.nim, R6-1 .. R6-11).
# ---------------------------------------------------------------------------

proc confinedNnp(name, extra: string): string =
  unit(name, "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
    "User=app\n" & extra & "ExecStart=/bin/true\n")

proc withGroup(line: string): proc (root: string) =
  result = proc (root: string) =
    writeFile(root / "etc/group", readFile(root / "etc/group") & line & "\n")

suite "reach reads setting values as systemd does (round 5)":
  test "control: ProtectSystem=strict with NoNewPrivileges=yes is let in":
    check not pendingRefused(confinedNnp("v0.service", ""))

  test "R6-10: ProtectSystem=Strict is ignored by systemd, so not confined":
    check pendingRefused(unit("v1.service", "[Service]\nProtectSystem=Strict\n" &
      "NoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n"))

  test "an ignored ProtectSystem= value keeps the earlier assignment":
    check not pendingRefused(unit("v2.service", "[Service]\nProtectSystem=strict\n" &
      "ProtectSystem=Strict\nNoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n"))

  test "R6-1: PermissionsStartOnly= is true for y, t, Y, T, TRUE and On":
    check not pendingRefused(confinedNnp("v3.service",
      "PermissionsStartOnly=no\nExecStartPre=/bin/true\n"))
    for v in ["y", "t", "Y", "T", "TRUE", "On"]:
      checkpoint "PermissionsStartOnly=" & v
      check pendingRefused(confinedNnp("v3.service",
        "PermissionsStartOnly=" & v & "\nExecStartPre=/bin/true\n"))

  test "NoNewPrivileges= is read with parse_boolean, and an ignored value sets nothing":
    for v in ["y", "Yes", "1", "on"]:
      checkpoint "NoNewPrivileges=" & v
      check not pendingRefused(unit("v4.service", "[Service]\n" &
        "ProtectSystem=strict\nNoNewPrivileges=" & v & "\nUser=app\n" &
        "ExecStart=/bin/true\n"))
    check pendingRefused(unit("v4.service", "[Service]\nProtectSystem=strict\n" &
      "NoNewPrivileges=maybe\nUser=app\nExecStart=/bin/true\n"))

suite "confinement needs NoNewPrivileges= and no privileged group (decision 54)":
  test "without NoNewPrivileges=yes a unit is not confined":
    check pendingRefused(unit("n1.service", "[Service]\nProtectSystem=strict\n" &
      "User=app\nExecStart=/bin/true\n"))

  test "R6-6: a member of a privileged group is not confined":
    for g in ["disk:x:6:app", "docker:x:999:app", "adm:x:4:app", "sudo:x:27:app"]:
      checkpoint g
      check pendingRefused(confinedNnp("n2.service", ""), withGroup(g))
    # Control: membership of a group not on the list.
    check not pendingRefused(confinedNnp("n2.service", ""),
                             withGroup("audio-ish:x:63:app"))

  test "a privileged primary group is not confined":
    check pendingRefused(confinedNnp("n3.service", "Group=adm\n"),
                         withGroup("adm:x:4:"))

  test "R6-7: a NOPASSWD sudo grant is held back by NoNewPrivileges=yes":
    proc sudoer(root: string) =
      hostFile(root, "/etc/sudoers.d/90-cloud-init-users",
               "app ALL=(ALL) NOPASSWD:ALL\n")
    check not pendingRefused(confinedNnp("n4.service", ""), sudoer)
    check pendingRefused(unit("n4.service", "[Service]\nProtectSystem=strict\n" &
      "User=app\nExecStart=/bin/true\n"), sudoer)

suite "the account under DynamicUser= (round 5)":
  test "R6-4: an instance's dynamic account is named after the unit's prefix":
    check not pendingRefused(unit("dyn@x.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nExecStart=/bin/true\n"))
    check pendingRefused(unit("root@x.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nExecStart=/bin/true\n"))

  test "R6-5: a userdb record is a static account":
    check not pendingRefused(unit("d5.service", "[Service]\nDynamicUser=yes\n" &
      "NoNewPrivileges=yes\nUser=ops\nExecStart=/bin/true\n"))
    check pendingRefused(unit("d5.service", "[Service]\nDynamicUser=yes\n" &
      "NoNewPrivileges=yes\nUser=ops\nExecStart=/bin/true\n"),
      proc (root: string) = hostFile(root, "/etc/userdb/ops.user",
        "{\"userName\":\"ops\",\"uid\":0,\"gid\":0,\"disposition\":\"system\"}\n"))

  test "a host whose NSS has other sources does not let a name be dynamic":
    check pendingRefused(unit("d6.service", "[Service]\nDynamicUser=yes\n" &
      "NoNewPrivileges=yes\nUser=svcx\nExecStart=/bin/true\n"),
      proc (root: string) = writeFile(root / "etc/nsswitch.conf",
        "passwd: files ldap\ngroup: files ldap\n"))

suite "every name a unit loads under (round 5)":
  test "R6-2: the drop-ins of an [Install] Alias= name are read":
    proc rootDropIn(root: string) =
      hostFile(root, "/run/systemd/system/a0alias.service.d/10-root.conf",
               "[Service]\nUser=root\n")
    check not pendingRefused(confinedNnp("a0.service", ""), rootDropIn)
    # [Install] after [Service], so the alias is the only change.
    let aliased = unit("a0.service", "[Service]\nProtectSystem=strict\n" &
      "NoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n[Install]\n" &
      "WantedBy=multi-user.target\nAlias=a0alias.service\n")
    check not pendingRefused(aliased)          # no host drop-in: let in
    check pendingRefused(aliased, rootDropIn)

  test "R6-2b: the drop-ins of a host link to the unit are read":
    check not pendingRefused(confinedNnp("a1.service", ""))
    check pendingRefused(confinedNnp("a1.service", ""),
      proc (root: string) =
        createDir(root / "etc/systemd/system")
        createSymlink("/etc/systemd/system/a1.service",
                      root / "etc/systemd/system/a1link.service")
        hostFile(root, "/etc/systemd/system/a1link.service.d/10-root.conf",
                 "[Service]\nUser=root\n"))

suite "the requirement covers what the profile starts (round 5)":
  proc installedAt(name: string): (string, string) =
    let root = fresh(name)
    let d = scratch / (name & "-carried")
    removeDir(d)
    copyDir(carriedDir(), d)
    discard restoreStateSet(d, stopped(), root = root)
    writeFile(installedMarkerPath(d), d & "\n")
    (root, d)

  test "a unit the profile starts but does not define requires the restore itself":
    let (root, d) = installedAt("req-wants")
    let starter = confinedNnp("w0.service", "ReadWritePaths=/var/lib/other\n")
    check carriedRequirementUnits(parseSystemProfile(starter), d, root).len == 0
    let wants = unit("w1.service", "[Unit]\nWants=dist9.service\n[Service]\n" &
      "ProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\nExecStart=/bin/true\n")
    let units = carriedRequirementUnits(parseSystemProfile(wants), d, root)
    check "dist9.service" in units
    check "w1.service" in units

  test "a unit the profile does not define but drops in on requires the restore through it":
    let (root, d) = installedAt("req-dropin")
    let dropIn = "systemd.systemDropIn {\n  unit = \"tuned9.service\"\n" &
      "  name = \"tune\"\n  content = \"[Service]\nEnvironment=A=1\n\"\n}\n"
    check carriedRequirementUnits(parseSystemProfile(
      confinedNnp("w0.service", "ReadWritePaths=/var/lib/other\n")), d, root).len == 0
    check carriedRequirementUnits(parseSystemProfile(dropIn), d, root) ==
      @["tuned9.service"]

  test "a Wants= chain within the profile: the wanted unit that reaches gets its own":
    let (root, d) = installedAt("req-chain")
    let a = unit("c-a.service", "[Unit]\nWants=c-b.service\n[Service]\n" &
      "ProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    let b = confinedNnp("c-b.service", "ReadWritePaths=/var/lib/ethereum/validator\n")
    let units = carriedRequirementUnits(parseSystemProfile(a & b), d, root)
    check units == @["c-b.service"]

suite "a stored plan is of the text the apply runs (round 5)":
  test "R6-8: a plan made before install-unit is stale once the requirement is due":
    let root = fresh("plan-r5")
    let d = scratch / "plan-r5-carried"
    removeDir(d)
    copyDir(carriedDir(), d)
    discard restoreStateSet(d, stopped(), root = root)
    let renamed = confinedNnp("p0.service",
      "ReadWritePaths=/var/lib/ethereum/validator\n")
    let state = fresh("plan-r5-state")
    let plan = producePlan(withCarriedRequirements(renamed, d, root), "h5")
    writePlanFile(planPath(state, plan.envelope.planId), plan.envelope)
    # Control: before install-unit the apply's text is the plan's.
    check digestProfileText(withCarriedRequirements(renamed, d, root)) ==
      plan.envelope.profileDigestHex
    writeFile(installedMarkerPath(d), d & "\n")
    check digestProfileText(withCarriedRequirements(renamed, d, root)) !=
      plan.envelope.profileDigestHex
    var why = ""
    try:
      discard runInfraApply(renamed, ApplyOptions(stateDir: state,
        hostIdentity: "h5", planId: plan.envelope.planId,
        reproExe: "/usr/bin/false", elevationMode: emNoElevate,
        noPreview: true, carriedStateDir: d, carriedStateRoot: root))
    except EPlanStale as e:
      why = e.msg
    checkpoint why
    check "carried-state requirements" in why

suite "the switch re-judges reach from the live unit (round 5)":
  proc props(t: openArray[(string, string)]): proc (k: string): string =
    var tab = initTable[string, string]()
    for (k, v) in t: tab[k] = v
    result = proc (k: string): string = tab.getOrDefault(k)

  test "a unit systemd loaded unconfined is a problem, whatever its text said":
    let liveRoot = fresh("live-r5")
    let lookup = hostAccountLookup(liveRoot)
    # Control: as systemd shows a confined unit.
    check liveConfinementProblem("l.service", props([("ProtectSystem", "strict"),
      ("DynamicUser", "no"), ("NoNewPrivileges", "yes"), ("User", "app"),
      ("Group", ""), ("SupplementaryGroups", "")]), lookup, liveRoot) == ""
    # systemd ignored ProtectSystem=Strict: it shows no.
    check liveConfinementProblem("l.service", props([("ProtectSystem", "no"),
      ("DynamicUser", "no"), ("NoNewPrivileges", "yes"), ("User", "app"),
      ("Group", ""), ("SupplementaryGroups", "")]), lookup, liveRoot).len > 0
    # An alias drop-in made it run as root.
    check liveConfinementProblem("l.service", props([("ProtectSystem", "strict"),
      ("DynamicUser", "no"), ("NoNewPrivileges", "yes"), ("User", "root"),
      ("Group", ""), ("SupplementaryGroups", "")]), lookup, liveRoot).len > 0
    check liveConfinementProblem("l.service", props([("ProtectSystem", "strict"),
      ("DynamicUser", "no"), ("NoNewPrivileges", "no"), ("User", "app"),
      ("Group", ""), ("SupplementaryGroups", "")]), lookup, liveRoot).len > 0

# ---------------------------------------------------------------------------
# Review round 6 (A13): the line and command grammar of a unit file, alias
# chains, the host's dependency directories, the reserved requirement name,
# and owner decisions 58 (privileged daemons) and 60 (the dependency
# closure). Each case has a control that passes first. Ported from the
# reviewer's probe (t_rev_a13r7_probe.nim, R7-1 .. R7-7).
# ---------------------------------------------------------------------------

proc installedR6(name: string): (string, string) =
  ## A scratch host with the validator's carried directory restored and
  ## carried state installed (the requirement applies).
  let root = fresh(name)
  let d = scratch / (name & "-carried")
  removeDir(d)
  copyDir(carriedDir(), d)
  discard restoreStateSet(d, stopped(), root = root)
  writeFile(installedMarkerPath(d), d & "\n")
  (root, d)

proc requiresRestore(text, u: string; d, root: string): bool =
  for r in parseSystemProfile(withCarriedRequirements(text, d, root)).resources:
    if r.kind == srkSystemdSystemDropIn and r.diUnit == u and
        ("Requires=" & CarriedRestoreUnit) in r.diContent:
      return true

suite "a unit's lines are read as systemd's config_parse reads them (round 6)":
  test "systemd's line grammar: continuation only after an unescaped backslash":
    check systemdLogicalLines("A=1\\\nB=2\n") == @["A=1 B=2"]
    check systemdLogicalLines("A=1\\\\\nB=2\n") == @["A=1\\\\", "B=2"]
    check systemdLogicalLines("A=1\\ \nB=2\n") == @["A=1\\ ", "B=2"]
    check systemdLogicalLines("A=1\\\n# c\nB=2\n") == @["A=1 B=2"]
    check systemdLogicalLines("A=1\r\nB=2\rC=3\n\nD=4") ==
      @["A=1", "B=2", "C=3", "", "D=4"]

  test "control: a host drop-in with a plain Environment= keeps the unit confined":
    check not pendingRefused(confinedNnp("c1.service", ""), proc (root: string) =
      hostFile(root, "/run/systemd/system/c1.service.d/10-env.conf",
               "[Service]\nEnvironment=X=a\n"))

  test "R7-1: a line ending in an escaped backslash does not continue":
    check pendingRefused(confinedNnp("c1.service", ""), proc (root: string) =
      hostFile(root, "/run/systemd/system/c1.service.d/10-env.conf",
               "[Service]\nEnvironment=X=a\\\\\nUser=root\n"))

  test "R7-1b: the same with a path the live check never compares":
    check pendingRefused(confinedNnp("c1.service", ""), proc (root: string) =
      hostFile(root, "/run/systemd/system/c1.service.d/10-env.conf",
               "[Service]\nEnvironment=X=a\\\\\n" &
               "ReadWritePaths=/var/lib/ethereum/validator\n"))

  test "R7-2: a line ending in backslash and a blank does not continue":
    check pendingRefused(confinedNnp("c2.service", ""), proc (root: string) =
      hostFile(root, "/run/systemd/system/c2.service.d/10-env.conf",
               "[Service]\nEnvironment=X=a\\ \n" &
               "ReadWritePaths=/var/lib/ethereum/validator\n"))

suite "every command of an Exec line is read (round 6)":
  test "systemd's command grammar: commands split at a lone ';'":
    var ok: bool
    let c = execCommands("/bin/true ; +/bin/id -u", ok)
    check ok and c.len == 2 and c[1].prefix == "+" and c[1].path == "/bin/id"
    let q = execCommands("/bin/echo \\; \"+x\" ; -/bin/x", ok)
    check ok and q.len == 2 and q[0].args == @[";", "+x"] and q[1].prefix == "-"
    discard execCommands("/bin/echo \"open", ok)
    check not ok

  test "control: a single unprivileged ExecStartPre= is let in":
    check not pendingRefused(confinedNnp("c3.service", "ExecStartPre=/bin/true\n"))

  test "R7-3: a privileged command after ';' in one Exec line":
    check pendingRefused(confinedNnp("c3.service",
      "ExecStartPre=/bin/true ; +/bin/true\n"))

  test "a quoted prefix is a prefix":
    check pendingRefused(confinedNnp("c3q.service",
      "ExecStartPre=\"+/bin/true\"\n"))

suite "an alias chain carries its drop-ins (round 6)":
  test "control: a link to the unit with no drop-ins is let in":
    check not pendingRefused(confinedNnp("c4.service", ""), proc (root: string) =
      createDir(root / "etc/systemd/system")
      createSymlink("/etc/systemd/system/c4.service",
                    root / "etc/systemd/system/c4l1.service"))

  test "R7-4: the drop-ins of an alias of an alias are read":
    check pendingRefused(confinedNnp("c4.service", ""), proc (root: string) =
      createDir(root / "etc/systemd/system")
      createSymlink("/etc/systemd/system/c4.service",
                    root / "etc/systemd/system/c4l1.service")
      createSymlink("/etc/systemd/system/c4l1.service",
                    root / "etc/systemd/system/c4l2.service")
      hostFile(root, "/etc/systemd/system/c4l2.service.d/10-root.conf",
               "[Service]\nUser=root\n"))

  test "an alias loop reaches everything":
    check pendingRefused(confinedNnp("c4.service", ""), proc (root: string) =
      createDir(root / "etc/systemd/system")
      createSymlink("/etc/systemd/system/c4x.service",
                    root / "etc/systemd/system/c4y.service")
      createSymlink("/etc/systemd/system/c4y.service",
                    root / "etc/systemd/system/c4x.service"))

suite "the host's dependency directories are read (round 6)":
  test "control: an empty .wants/ directory adds nothing":
    check not pendingRefused(confinedNnp("c5.service", ""), proc (root: string) =
      createDir(root / "etc/systemd/system/c5.service.wants"))

  test "R7-5: a host .wants/ link starts a unit the profile does not define":
    check pendingRefused(confinedNnp("c5.service", ""), proc (root: string) =
      createDir(root / "etc/systemd/system/c5.service.wants")
      createSymlink("/lib/systemd/system/dist5.service",
                    root / "etc/systemd/system/c5.service.wants/dist5.service"))

  test "a .requires/ link of the template, and a masked link that adds nothing":
    check pendingRefused(confinedNnp("c5@x.service", ""), proc (root: string) =
      createDir(root / "run/systemd/system/c5@.service.requires")
      createSymlink("/lib/systemd/system/dist5.service",
                    root / "run/systemd/system/c5@.service.requires/dist5.service"))
    check not pendingRefused(confinedNnp("c5.service", ""), proc (root: string) =
      createDir(root / "etc/systemd/system/c5.service.upholds")
      createSymlink("/dev/null",
                    root / "etc/systemd/system/c5.service.upholds/dist5.service"))

  test "R7-7: the unit a host .wants/ link starts gets the requirement":
    let (root, d) = installedR6("r7-wants")
    let starter = confinedNnp("c7.service", "ReadWritePaths=/var/lib/other\n")
    check not requiresRestore(starter, "dist7.service", d, root)
    createDir(root / "etc/systemd/system/c7.service.wants")
    createSymlink("/lib/systemd/system/dist7.service",
                  root / "etc/systemd/system/c7.service.wants/dist7.service")
    check requiresRestore(starter, "dist7.service", d, root)

suite "the requirement's drop-in name is reserved (round 6)":
  test "control: without a drop-in of the name the reaching unit requires the restore":
    let (root, d) = installedR6("r7-name0")
    check requiresRestore(confinedNnp("c6.service",
      "ReadWritePaths=/var/lib/ethereum/validator\n"), "c6.service", d, root)

  test "R7-6: a profile drop-in named state-restore is refused":
    let (root, d) = installedR6("r7-name")
    let own = confinedNnp("c6.service",
      "ReadWritePaths=/var/lib/ethereum/validator\n") &
      "systemd.systemDropIn {\n  unit = \"c6.service\"\n" &
      "  name = \"state-restore\"\n  content = \"[Unit]\nDescription=x\n\"\n}\n"
    let why = carriedStateRefusal(parseSystemProfile(own), d, root)
    checkpoint why
    check why.startsWith("ECarriedStatePending") and "reserved" in why
    var raised = false
    try: discard withCarriedRequirements(own, d, root)
    except ECarriedStatePending: raised = true
    check raised

  test "the generation's own requirement, applied again, is let through":
    let (root, d) = installedR6("r7-name2")
    let reaching = confinedNnp("c6.service",
      "ReadWritePaths=/var/lib/ethereum/validator\n")
    let applied = withCarriedRequirements(reaching, d, root)
    check carriedStateRefusal(parseSystemProfile(applied), d, root) == ""
    check withCarriedRequirements(applied, d, root) == applied

suite "a privileged daemon's grant reaches everything (decision 58)":
  test "control: no polkit rule or D-Bus policy names the account":
    check not pendingRefused(confinedNnp("d0.service", ""), proc (root: string) =
      hostFile(root, "/usr/share/polkit-1/rules.d/10-net.rules",
        "polkit.addRule(function(action, subject) {\n" &
        "  if (action.id.indexOf(\"org.freedesktop.network1.\") == 0 &&\n" &
        "      subject.user == \"systemd-network\") {\n" &
        "    return polkit.Result.YES;\n  }\n});\n")
      hostFile(root, "/usr/share/polkit-1/rules.d/40-admin.rules",
        "polkit.addAdminRule(function(action, subject) {\n" &
        "  return [\"unix-group:sudo\"];\n});\n")
      hostFile(root, "/usr/share/dbus-1/system.conf",
        "<busconfig><policy context=\"default\"><allow user=\"*\"/>" &
        "</policy><includedir>system.d</includedir>" &
        "<include if_selinux_enabled=\"yes\" selinux_root_relative=\"yes\">" &
        "contexts/dbus_contexts</include></busconfig>\n")
      hostFile(root, "/usr/share/dbus-1/system.d/x.conf",
        "<busconfig><policy user=\"root\"><allow own=\"x\"/></policy>" &
        "<policy group=\"validator\"><allow send_destination=\"x\"/>" &
        "</policy></busconfig>\n"))

  test "a polkit rule that grants the account, by name or by group":
    check pendingRefused(confinedNnp("d1.service", ""), proc (root: string) =
      hostFile(root, "/etc/polkit-1/rules.d/50-app.rules",
        "polkit.addRule(function(action, subject) {\n" &
        "  if (subject.user == \"app\") { return polkit.Result.YES; }\n});\n"))
    check pendingRefused(confinedNnp("d1.service", ""), proc (root: string) =
      hostFile(root, "/etc/polkit-1/rules.d/50-app.rules",
        "polkit.addRule(function(action, subject) {\n" &
        "  if (subject.isInGroup(\"app\")) return \"yes\";\n});\n"))

  test "a polkit rule this check cannot judge counts as naming the account":
    check pendingRefused(confinedNnp("d2.service", ""), proc (root: string) =
      hostFile(root, "/etc/polkit-1/rules.d/50-any.rules",
        "polkit.addRule(function(action, subject) {\n" &
        "  return subject.local ? polkit.Result.YES : polkit.Result.NO;\n});\n"))
    check pendingRefused(confinedNnp("d2.service", ""), proc (root: string) =
      hostFile(root, "/etc/polkit-1/rules.d/50-all.rules",
        "polkit.addRule(function(action, subject) {\n" &
        "  if (action.id == \"org.x\") return polkit.Result.YES;\n});\n"))

  test "a .pkla identity and a D-Bus policy naming the account or a group":
    check pendingRefused(confinedNnp("d3.service", ""), proc (root: string) =
      hostFile(root, "/etc/polkit-1/localauthority/50-local.d/x.pkla",
        "[x]\nIdentity=unix-user:app\nAction=*\nResultAny=yes\n"))
    check pendingRefused(confinedNnp("d3.service", ""), proc (root: string) =
      hostFile(root, "/etc/dbus-1/system.d/app.conf",
        "<busconfig><policy group=\"app\"><allow own=\"org.app\"/></policy>" &
        "</busconfig>\n"))
    check pendingRefused(confinedNnp("d3.service", ""), proc (root: string) =
      hostFile(root, "/etc/dbus-1/system.d/app.conf",
        "<busconfig><include>/opt/elsewhere.conf</include></busconfig>\n"))

suite "the requirement follows the distribution's dependency closure (decision 60)":
  test "a service started only through a distribution unit's dependencies":
    let (root, d) = installedR6("r7-closure")
    hostFile(root, "/lib/systemd/system/dista.service",
      "[Unit]\nWants=distb.service distc.service\n[Service]\nExecStart=/bin/true\n")
    hostFile(root, "/lib/systemd/system/distb.service",
      "[Service]\nExecStart=/bin/true\n")
    hostFile(root, "/lib/systemd/system/distc.service",
      "[Service]\nExecStart=/bin/true\n")
    # The boot starts distc anyway: it is the distribution's.
    hostFile(root, "/lib/systemd/system/default.target",
      "[Unit]\nWants=distc.service\n")
    let starter = unit("cl.service", "[Unit]\nWants=dista.service\n[Service]\n" &
      "ProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    let units = carriedRequirementUnits(parseSystemProfile(starter), d, root)
    checkpoint $units
    check "dista.service" in units          # control: round 5's direct rule
    check "distb.service" in units          # through dista's Wants=
    check "distc.service" notin units       # the boot starts it anyway

  test "a unit whose file is missing keeps the requirement it has":
    let (root, d) = installedR6("r7-closure2")
    let starter = unit("cm.service", "[Unit]\nWants=nofile.service\n[Service]\n" &
      "ProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    check "nofile.service" in carriedRequirementUnits(parseSystemProfile(starter), d, root)

suite "the switch judges its services in every switch (round 7, finding 1)":
  test "a switch that writes no unit file holds, reloads and judges the services":
    # A switch changing only a file a confined service depends_on (or its
    # credentials) restarts it at step 7: carried state on the host, the
    # services are judged anyway.
    let d = liveCheckAtStep6(anyUnitChange = false, replaying = false,
                             recordOnly = false, ["a.service", "b.service"])
    check d.reload
    check d.judged == @["a.service", "b.service"]

  test "control: no services to judge and no unit change, no reload":
    let d = liveCheckAtStep6(false, false, false, [])
    check not d.reload
    check d.judged.len == 0

  test "control: a unit change reloads; a record-only switch judges nothing":
    check liveCheckAtStep6(true, false, false, []).reload
    let r = liveCheckAtStep6(true, false, true, ["a.service"])
    check r.reload
    check r.judged.len == 0

suite "the boot closure leaves the generation's drop-ins out (round 7)":
  proc bootHost(root: string) =
    hostFile(root, "/lib/systemd/system/default.target",
      "[Unit]\nWants=multi-user.target\n")
    hostFile(root, "/lib/systemd/system/multi-user.target", "[Unit]\n")
    hostFile(root, "/lib/systemd/system/cronx.service",
      "[Service]\nExecStart=/bin/true\n")
    createDir(root / "etc/systemd/system/multi-user.target.wants")
    createSymlink("/lib/systemd/system/cronx.service",
      root / "etc/systemd/system/multi-user.target.wants/cronx.service")
    hostFile(root, "/lib/systemd/system/distb.service",
      "[Service]\nExecStart=/bin/true\n")

  const DropIn = "systemd.systemDropIn {\n  unit = \"cronx.service\"\n" &
    "  name = \"x\"\n  content = \"[Unit]\nWants=distb.service\n\"\n}\n"

  test "P60-1 a profile drop-in's Wants= on a boot unit, before it is written":
    let (root, d) = installedR6("r8-p601")
    bootHost(root)
    let units = carriedRequirementUnits(parseSystemProfile(
      confinedNnp("p60.service", "ReadWritePaths=/var/lib/other\n") & DropIn), d, root)
    checkpoint $units
    check units == @["cronx.service", "distb.service"]

  test "P60-2 the same once an earlier generation wrote that drop-in":
    # The generation's own 50-repro-x.conf is on the host from the first
    # apply on; distb is still started only through the profile.
    let (root, d) = installedR6("r8-p602")
    bootHost(root)
    hostFile(root, "/etc/systemd/system/cronx.service.d/50-repro-x.conf",
      "[Unit]\nWants=distb.service\n")
    let units = carriedRequirementUnits(parseSystemProfile(
      confinedNnp("p60.service", "ReadWritePaths=/var/lib/other\n") & DropIn), d, root)
    checkpoint $units
    check units == @["cronx.service", "distb.service"]

  test "control: a host drop-in on a boot unit is the boot's":
    # Not the generation's (the profile declares no drop-in named y): the
    # boot starts distb through it, so distb gets no requirement.
    let (root, d) = installedR6("r8-p60c")
    bootHost(root)
    hostFile(root, "/etc/systemd/system/cronx.service.d/50-repro-y.conf",
      "[Unit]\nWants=distb.service\n")
    let units = carriedRequirementUnits(parseSystemProfile(
      confinedNnp("p60.service", "ReadWritePaths=/var/lib/other\n") & DropIn), d, root)
    checkpoint $units
    check "distb.service" notin units

suite "a polkit rule that rebinds subject cannot be judged (round 7)":
  proc rule(body: string): proc (root: string) =
    result = proc (root: string) =
      hostFile(root, "/etc/polkit-1/rules.d/50-x.rules", body)

  test "control: a rule guarded by another account's subject.user":
    check not pendingRefused(confinedNnp("p58c.service", ""), rule(
      "polkit.addRule(function(action, subject) {\n" &
      "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n"))
    check not pendingRefused(confinedNnp("p58c.service", ""), rule(
      "polkit.addRule((action, subject) => {\n" &
      "  if (subject.isInGroup(\"bob\")) { return polkit.Result.YES; }\n});\n"))

  test "P58-1 a var declaration rebinding subject":
    check pendingRefused(confinedNnp("p581.service", ""), rule(
      "polkit.addRule(function(action, subject) {\n" &
      "  var subject = {user: \"bob\"};\n" &
      "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n"))

  test "P58-2 a plain assignment to subject":
    check pendingRefused(confinedNnp("p582.service", ""), rule(
      "polkit.addRule(function(action, subject) {\n" &
      "  subject = {user: \"bob\"};\n" &
      "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n"))

  test "let, const, a member assignment, and an increment":
    for line in ["let subject = {user: \"bob\"};",
                 "const subject = {user: \"bob\"};",
                 "subject.user = \"bob\";",
                 "subject.user += \"\";",
                 "subject.user++;"]:
      checkpoint line
      check pendingRefused(confinedNnp("p58m.service", ""), rule(
        "polkit.addRule(function(action, subject) {\n  " & line & "\n" &
        "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n"))

  test "subject bound elsewhere, aliased, or read outside its rule":
    for body in [
        # a nested function's own parameter
        "polkit.addRule(function(action, subject) {\n" &
          "  function ok(subject) { return subject.user == \"bob\"; }\n" &
          "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n",
        # the rule's subject in another position
        "polkit.addRule(function(subject, action) {\n" &
          "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n",
        # a catch binding
        "polkit.addRule(function(action, subject) {\n" &
          "  try { x(); } catch (subject) { }\n" &
          "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n",
        # passed whole
        "polkit.addRule(function(action, subject) {\n" &
          "  Object.assign(subject, {user: \"bob\"});\n" &
          "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n",
        # a rule whose parameter is not named subject: the guard reads a global
        "polkit.addRule(function(action, s) {\n" &
          "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n",
        # arguments rebinds a parameter in sloppy mode
        "polkit.addRule(function(action, subject) {\n" &
          "  arguments[1] = {user: \"bob\"};\n" &
          "  if (subject.user == \"bob\") { return polkit.Result.YES; }\n});\n"]:
      checkpoint body
      check pendingRefused(confinedNnp("p58o.service", ""), rule(body))

suite "the drivers' start jobs are issued again after the check (decision 79)":
  proc op(name: string; enabled: bool; held = false): PlannedOperation =
    PlannedOperation(operation: PrivilegedOperation(kind: pokSystemdSystemUnit,
      suName: name, suEnabled: enabled, suRestartHeld: held))

  proc activeOnly(units: openArray[string]): proc (u: string): bool =
    let s = @units
    result = proc (u: string): bool = u in s

  test "control: a static unit the plan does not enable and that is not running":
    check driverStartJobs([op("st.service", false)], activeOnly([])).len == 0

  test "an enabled target's job is issued again":
    let jobs = driverStartJobs([op("t.target", true), op("st.service", false)],
                               activeOnly([]))
    checkpoint $jobs
    check jobs == @["t.target"]

  test "an enabled socket's job is issued again":
    let jobs = driverStartJobs([op("k.socket", true), op("st.service", false)],
                               activeOnly([]))
    checkpoint $jobs
    check jobs == @["k.socket"]

  test "a running unit's restart is issued again, unless the profile holds it":
    let jobs = driverStartJobs([op("r.service", false),
      op("h.service", false, held = true)], activeOnly(["r.service", "h.service"]))
    checkpoint $jobs
    check jobs == @["r.service"]

suite "the live cross-check is one shared check (round 6)":
  test "liveReachUnits names the services judged confined, liveReachProblems judges them":
    let (root, d) = installedR6("r7-live")
    let p = parseSystemProfile(confinedNnp("lv.service", "ReadWritePaths=/var/lib/other\n") &
      confinedNnp("lw.service", "ReadWritePaths=/var/lib/ethereum/validator\n"))
    let units = liveReachUnits(p, d, root)
    check units == @["lv.service", "lw.service"]
    let confinedShow = proc (u: string): Table[string, string] =
      {"ProtectSystem": "strict", "DynamicUser": "no", "NoNewPrivileges": "yes",
       "User": "app", "Group": "", "SupplementaryGroups": ""}.toTable
    check liveReachProblems(["lv.service"], p, confinedShow, root).len == 0
    let rootShow = proc (u: string): Table[string, string] =
      {"ProtectSystem": "strict", "DynamicUser": "no", "NoNewPrivileges": "yes",
       "User": "root", "Group": "", "SupplementaryGroups": ""}.toTable
    let probs = liveReachProblems(["lv.service"], p, rootShow, root)
    check probs.len == 1 and "lv.service as systemd loaded it" in probs[0]
    let failing = proc (u: string): Table[string, string] =
      raise newException(OSError, "no such unit")
    check liveReachProblems(["lv.service"], p, failing, root).len == 1

removeDir(scratch)

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
## round 8: ``template-live-by-name`` (decision 135, a template read
## through its instances);
## round 7: ``narrowed-live-set`` (a switch that writes no unit file; the
## decision alone -- its use at the switch's step 6 is falsified end to end
## by case 2e of ``tests/e2e/addon/t_e2e_addon_adopt_hand_configured_service``,
## a credentials-only switch, A13 review round 8),
## ``boot-closure-reads-generation-dropins`` (P60-2),
## ``polkit-subject-rebind-trusted`` (P58-1, P58-2 and the other binding
## forms), ``reissue-skips-targets`` and ``reissue-skips-sockets``
## (decision 79, each on its own case); 2026-11-14:
## ``reissue-skips-unit-state``, ``reissue-skips-timers``,
## ``refusal-holds-every-unit``, ``shared-hold-lifted-by-passed-instance`` and
## ``trigger-fired-under-hold-not-started``.
##
## *Mocking.* The unit liveness (``AlivenessFn``), as in
## ``t_addon_state_sets``: a unit test has no systemd unit whose cgroup the
## production check could read. The hold is off (``hold = false``): writing
## it needs root and a running systemd (the conversion gate runs it). The
## host apply lock is the real lock, at a test path (``REPRO_HOST_APPLY_LOCK``),
## held by a real second process (``flock``).

import std/[json, os, osproc, sequtils, sets, strutils, tables, unittest]

import repro_core/host_apply_lock

import repro_infra
import repro_infra/systemd_syntax
import repro_infra/start_holds
from repro_test_support import testCaseScratchSlug
import repro_elevation
from repro_elevation/posix_system_parse import systemdUnitNameError
import repro_addon/[addon_apply, adoption_cli, reassert, secrets_ops, state_sets, transitions]
import repro_addon/agent_checks

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

proc simHost*(log: ref seq[string]; failing: seq[string] = @[];
              skipped: seq[string] = @[]): LiveHost =
  ## A host whose units start as systemd starts them: a unit that starts is
  ## then reported ``ActiveState=active``; one in ``failing`` fails its
  ## start; one in ``skipped`` has a condition hold, so its start exits 0
  ## and leaves it inactive, ``ConditionResult=no`` -- what systemd does
  ## (A13 review round 11, H1: a fake that marks every started unit active
  ## hid exactly that).
  let active = new seq[string]
  LiveHost(
    isActive: proc (u: string): bool = u in active[],
    show: proc (u: string): Table[string, string] =
      result = {"LoadState": "loaded"}.toTable
      if u in active[]: result["ActiveState"] = "active"
      else: result["ActiveState"] = "inactive"
      if u in skipped: result["ConditionResult"] = "no",
    start: proc (u: string): tuple[ok: bool, output: string] =
      log[].add("start " & u)
      if u in failing: return (false, "Job failed")
      if u notin skipped and u notin active[]: active[].add(u)
      (true, ""),
    stop: proc (u: string): tuple[ok: bool, output: string] =
      log[].add("stop " & u)
      active[].keepItIf(it != u)
      (true, ""),
    resetFailed: proc (u: string) = log[].add("reset-failed " & u))

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

const PendingPrefix = "ECarriedStatePending: carried state is not restored yet: " &
  "/var/lib/ethereum/validator ("

proc pendingDecision(text, why, resource, reason: string): bool =
  ## The oracle both refusal helpers share. ``why`` is ``refusal``'s answer;
  ## ``refusal`` itself is called outside any ``try``, so a parse or fixture
  ## error propagates and fails the test instead of counting as a refusal
  ## (or, through ``check not``, as an admission).
  ##
  ## Admission is an empty answer, and only that. Any other answer must be a
  ## pending refusal of the carried path ``/var/lib/ethereum/validator``,
  ## naming a resource the case itself declares; anything else is an error
  ## the case did not intend, and raises. ``resource`` (``kind:name``) and
  ## ``reason`` pin the refusal further: when given, a refusal of another
  ## resource or for another reason is not the one the case asserts.
  checkpoint "refusal: " & why
  if why.len == 0: return false
  if not why.startsWith(PendingPrefix):
    raise newException(ValueError, "not a carried-state refusal: " & why)
  let named = why[PendingPrefix.len .. ^1]
  let colon = named.find(':')
  if colon < 0:
    raise newException(ValueError, "a refusal naming no resource: " & why)
  var stop = colon + 1
  while stop < named.len and named[stop] notin {':', ')'}: inc stop
  let name = named[colon + 1 ..< stop]
  if ("\"" & name & "\"") notin text:
    raise newException(ValueError, "a refusal of " & named[0 ..< stop] &
      ", which the case does not declare: " & why)
  if resource.len > 0 and named[0 ..< stop] != resource: return false
  if reason.len > 0 and reason notin named[stop .. ^1]: return false
  true

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
    check runStateCommand(StateCommand(verb: "install-unit", root: root)) == 0
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
    check "Before=shutdown.target eth-validator.service" in unitText
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
    check runStateCommand(StateCommand(verb: "install-unit",
      fromDir: "/srv/elsewhere", root: fresh("root-from"))) == 2

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
  proc refused(text: string; resource = ""; reason = ""): bool =
    pendingDecision(text, refusal(text, fresh("dst-dd")), resource, reason)

  proc confinedWith(name, extra: string): string =
    unit(name, "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" & extra &
      "ExecStart=/bin/true\n")

  test "this suite's helper lets a parse error through, as a failure":
    # An unterminated stanza is the parser's error, not a decision: it must
    # neither count as a refusal nor, through ``check not``, as admission.
    expect ESystemProfileInvalid:
      discard refused("systemd.systemUnit {\n  name = \"m.service\"\n")

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
    # The holder marks `ready` only once flock(1) has granted it the lock,
    # and the apply starts only after that marker exists. A fixed sleep
    # here raced the holder on a loaded host: when `flock` started late the
    # apply took the lock first, saw no hold, and the case failed for a
    # product defect that did not exist (reprobuild-pm issue
    # 2026-11-15-carried-state-host-lock-recheck-test-races-its-flock-holder).
    let ready = scratch / "host-apply-2.ready"
    removeFile(ready)
    let holder = startProcess("flock", args = [lock, "sh", "-c",
      "touch " & quoteShell(ready) & "; sleep 2; mkdir -p " &
      quoteShell(holdDir) & " && echo x > " &
      quoteShell(holdDir / HoldDropInName)], options = {poUsePath})
    var waited = 0
    while not fileExists(ready) and waited < 60_000:
      sleep(50)
      waited += 50
    require fileExists(ready)   # the holder never got the lock: say so
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

proc pendingRefused(text: string; prepare: proc (root: string) = nil;
                    resource = ""; reason = ""): bool =
  ## Whether an apply of ``text`` is refused while the validator's carried
  ## directory is pending, on a scratch host ``prepare`` may add files to.
  ## ``pendingDecision`` says what counts.
  let root = fresh("dst-r4")
  if prepare != nil: prepare(root)
  pendingDecision(text, refusal(text, root), resource, reason)

proc confinedR(name, extra: string): string =
  unit(name, "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" & extra &
    "ExecStart=/bin/true\n")

proc hostFile(root, path, content: string) =
  createDir((root & path).parentDir)
  writeFile(root & path, content)

suite "the refusal oracle counts only the refusal a case intends":
  # A malformed profile: the parser rejects it before any carried-state
  # decision. It must fail the case, never pass for a refusal or admission.
  const Malformed = "systemd.systemUnit {\n  name = \"m.service\"\n  content = \"x\"\n"

  test "an unrelated parse error propagates through both helpers":
    # The parser's own error, so the case cannot pass on some other failure.
    expect ESystemProfileInvalid:
      discard pendingRefused(Malformed)
    expect ESystemProfileInvalid:
      discard pendingDecision(Malformed, refusal(Malformed, fresh("dst-or")), "", "")

  test "a genuine refusal counts only for its own resource and reason":
    let text = unit("or1.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nUser=root\nExecStart=/bin/true\n")
    check pendingRefused(text)
    check pendingRefused(text, resource = "systemUnit:or1.service",
                         reason = "runs as root (root)")
    check not pendingRefused(text, resource = "systemUnit:other.service")
    check not pendingRefused(text, reason = "holds the root group")

  test "admission is an empty answer, and any other answer is an error":
    let text = unit("or2.service", "[Service]\nExecStart=/bin/true\n")
    check not pendingDecision(text, "", "", "")
    expect ValueError:
      discard pendingDecision(text, "ESomethingElse: no", "", "")
    expect ValueError:
      discard pendingDecision(text, PendingPrefix & "systemUnit:undeclared.service)", "", "")

suite "reach judges the account systemd will use (round 4)":
  test "control: a confined unit of a non-root account elsewhere is let in":
    check not pendingRefused(confinedR("c0.service",
      "ReadWritePaths=/var/lib/other\n"))

  test "F1: DynamicUser=yes with User=root runs as root":
    check pendingRefused(unit("f1.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nUser=root\nExecStart=/bin/true\n"),
      resource = "systemUnit:f1.service", reason = "runs as root (root)")

  test "F1b: DynamicUser=yes with Group=root holds gid 0":
    check pendingRefused(unit("f1b.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nUser=app\nGroup=root\nExecStart=/bin/true\n"),
      resource = "systemUnit:f1b.service", reason = "holds the root group (root)")

  test "F2: User=%U is the system manager's uid, 0":
    check pendingRefused(unit("f2.service",
      "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=%U\nExecStart=/bin/true\n"),
      resource = "systemUnit:f2.service", reason = "runs as root (0)")

  test "F2b: a template's User=%i names no account (DefaultInstance=root)":
    check pendingRefused(unit("f2b@.service",
      "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=%i\nExecStart=/bin/true\n" &
      "[Install]\nWantedBy=multi-user.target\nDefaultInstance=root\n"),
      resource = "systemUnit:f2b@.service",
      reason = "its account does not resolve: User=%i")

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
      "  content = \"[Timer]\nUnit=apt-daily.service\n\"\n}\n",
      resource = "systemTimer:t3.timer",
      reason = "it starts apt-daily.service, which the profile does not define")

  test "F3b: a profile timer's drop-in with a section not understood":
    check pendingRefused("systemd.systemTimer {\n  name = \"t4.timer\"\n" &
      "  content = \"[Timer]\nOnActiveSec=1\nUnit=c0.service\n\"\n}\n" &
      confinedR("c0.service", "") &
      "systemd.systemDropIn {\n  unit = \"t4.timer\"\n  name = \"20-x\"\n" &
      "  content = \"[X-Unknown]\nFoo=bar\n\"\n}\n",
      resource = "systemTimer:t4.timer", reason = "[X-Unknown] Foo= (not understood here)")

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

  for path in ["/etc/systemd/system/c0-@1.service.d/10-x.conf",
               "/run/systemd/system/c0-@.service.d/10-x.conf"]:
    test "a host source is read: an instance's dashed prefix keeps the " &
        "instance, " & path:
      # systemd v257 unit_file_find_dirs(): c0-x@1.service reads
      # c0-@1.service.d/ and c0-@.service.d/ (the prefix keeps the
      # instance). Red under dropins-skip-instance-prefix.
      check not pendingRefused(confinedR("c0-x@1.service", ""))
      check pendingRefused(confinedR("c0-x@1.service", ""),
        proc (root: string) = hostFile(root, path, "[Service]\nUser=root\n"))

  test "control: another instance's dashed prefix is not read":
    check not pendingRefused(confinedR("c0-x@2.service", ""),
      proc (root: string) = hostFile(root,
        "/etc/systemd/system/c0-@1.service.d/10-x.conf",
        "[Service]\nUser=root\n"))

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
      "MakeDirectory=yes\nUnit=c0.service\n") & confinedR("c0.service", ""),
      resource = "systemUnit:f4.path")

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

suite "the live check judges a template through its instances (decision 135)":
  # systemd's show refuses a template name ("neither a valid invocation ID
  # nor unit name"): the stub raises for one, as systemd does.
  proc stubShow(rootUnits: seq[string]): proc (u: string): Table[string, string] =
    result = proc (u: string): Table[string, string] =
      if isTemplateUnit(u):
        raise newException(OSError, "Unit name " & u &
          " is neither a valid invocation ID nor unit name.")
      var t = {"ProtectSystem": "strict", "DynamicUser": "no",
               "NoNewPrivileges": "yes", "User": "app", "Group": "app",
               "SupplementaryGroups": ""}.toTable
      if u in rootUnits: t["User"] = "root"
      t

  const Tpl = "systemd.systemUnit {\n  name = \"tpl@.service\"\n" &
    "  content = \"[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\n" &
    "User=app\nReadWritePaths=/var/lib/other\nExecStart=/bin/true\n\"\n}\n"
  const Starter = "systemd.systemUnit {\n  name = \"st.target\"\n" &
    "  content = \"[Unit]\nWants=tpl@a.service\n\"\n}\n"

  test "the judged names: the observation instance, the generation's and the running instances":
    let p = parseSystemProfile(Tpl & Starter)
    let names = liveJudgedNames(["tpl@.service", "plain.service"], p,
      proc (t: string): seq[string] = @["tpl@b.service"])
    checkpoint $names
    check names == @["tpl@repro-addon-observe.service", "tpl@a.service",
                     "tpl@b.service", "plain.service"]
    check "tpl@.service" notin names

  test "a confined template whose instances systemd loads confined passes":
    let (root, d) = installedR6("r9-tpl")
    let p = parseSystemProfile(Tpl & Starter)
    check liveReachUnits(p, d, root) == @["tpl@.service"]
    let problems = liveReachProblems(liveReachUnits(p, d, root), p,
      stubShow(@[]), root, proc (t: string): seq[string] = @["tpl@b.service"])
    checkpoint $problems
    check problems.len == 0

  test "an instance systemd loads as root is refused, by its instance name":
    let (root, d) = installedR6("r9-tpl2")
    let p = parseSystemProfile(Tpl & Starter)
    let problems = liveReachProblems(liveReachUnits(p, d, root), p,
      stubShow(@["tpl@b.service"]), root, proc (t: string): seq[string] = @["tpl@b.service"])
    checkpoint $problems
    check problems.len == 1
    check "tpl@b.service as systemd loaded it is not confined" in problems[0]

  test "list-units output: the instances, never the template or the observation instance":
    let out0 = "tpl@a.service loaded active running A\n" &
      "tpl@repro-addon-observe.service loaded inactive dead O\n" &
      "tpl@.service loaded inactive dead T\nother@x.service loaded active running X\n"
    check parseRunningInstances("tpl@.service", out0) == @["tpl@a.service"]
    check runningInstancesArgs("tpl@.service")[^1] == "tpl@*.service"

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

suite "every driver's start is issued again after the check (decision 79, 2026-11-14)":
  ## Mocking: ``LiveHost`` stands for systemd's answers and ``start``: a unit
  ## test has no systemd whose jobs or timers it could read (the conversion
  ## gate runs the real ones). What is asserted is which units are started,
  ## in which order, and which are left held.
  proc unitState(name: string; running: bool): PlannedOperation =
    PlannedOperation(operation: PrivilegedOperation(kind: pokSystemdUnitState,
      usName: name, usEnabled: true, usRunning: running))

  proc timer(name: string; running: bool): PlannedOperation =
    PlannedOperation(operation: PrivilegedOperation(kind: pokSystemdSystemTimer,
      stName: name, stEnabled: true, stRunning: running))

  proc none(u: string): bool = false

  test "a unitState start of a unit the profile does not own is issued again":
    check driverStartJobs([unitState("multi-user.target", true)], none) ==
      @["multi-user.target"]

  test "a unitState that was already running, stopped or destroyed has no job":
    check driverStartJobs([unitState("multi-user.target", true)],
      proc (u: string): bool = true).len == 0
    check driverStartJobs([unitState("x.service", false)], none).len == 0
    check driverStartJobs([PlannedOperation(operation: PrivilegedOperation(
      kind: pokSystemdUnitState, usName: "d.service", usRunning: true,
      usDestroy: true))], none).len == 0

  test "a running systemTimer's start is issued again, a stopped one's is not":
    check driverStartJobs([timer("x.timer", true), timer("y.timer", false)],
      none) == @["x.timer"]
    check driverStartJobs([PlannedOperation(operation: PrivilegedOperation(
      kind: pokSystemdSystemTimer, stName: "d.timer", stRunning: true,
      stDestroy: true))], none).len == 0

  proc fakeHost(active: seq[string]; shows: Table[string, Table[string, string]];
                log: ref seq[string]; failing = ""): LiveHost =
    LiveHost(
      isActive: proc (u: string): bool = u in active,
      show: proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "no unit " & u)
        shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] =
        log[].add(u)
        (u != failing, "refused " & u))

  let held = {"ConditionResult": "no", "ConditionTimestampMonotonic": "5000"}.toTable
  let heldBefore = {"ConditionResult": "no", "ConditionTimestampMonotonic": "900"}.toTable
  let passing = {"ConditionResult": "yes", "ConditionTimestampMonotonic": "5000"}.toTable
  let neverTested = {"ConditionResult": "yes", "ConditionTimestampMonotonic": "0"}.toTable
  let timerShows = {"x.timer": {"Triggers": "x.service"}.toTable}.toTable

  test "a trigger that fired under the hold: its held service is started once":
    var shows = timerShows
    shows["x.service"] = held
    var log = new seq[string]
    let host = fakeHost(@["x.timer"], shows, log)
    let fired = firedUnderHold(["x.timer"], ["x.service"], [], host, 1000)
    check fired == @["x.service"]
    let p = parseSystemProfile("")
    check releaseStarts(p, ["x.service"], ["x.service"], [], [], ["x.timer"],
      fired, host).len == 0
    check log[] == @["x.timer", "x.service"]

  test "a service the hold did not skip is left to its trigger":
    for st in [heldBefore, passing, neverTested]:
      var shows = timerShows
      shows["x.service"] = st
      var log = new seq[string]
      check firedUnderHold(["x.timer"], ["x.service"], [], fakeHost(@[], shows, log), 1000).len == 0
    # already active, not judged by the check, or refused
    var shows = timerShows
    shows["x.service"] = held
    var log = new seq[string]
    check firedUnderHold(["x.timer"], ["x.service"], [],
      fakeHost(@["x.service"], shows, log), 1000).len == 0
    check firedUnderHold(["x.timer"], ["other.service"], [],
      fakeHost(@[], shows, log), 1000).len == 0
    check firedUnderHold(["x.timer"], ["x.service"], ["x.service"],
      fakeHost(@[], shows, log), 1000).len == 0

  test "a path unit's trigger is read the same way":
    var shows = {"w.path": {"Triggers": "w.service"}.toTable}.toTable
    shows["w.service"] = held
    var log = new seq[string]
    check firedUnderHold(["w.path"], ["w.service"], [], fakeHost(@[], shows, log), 1000) ==
      @["w.service"]

  test "one refusal holds only the refused unit; the others start":
    let problems = ["floored unit: bad.service as systemd loaded it reaches the carried state"]
    let refused = refusedUnits(["ok.service", "bad.service"], problems)
    check refused == @["bad.service"]
    var log = new seq[string]
    let host = fakeHost(@["ok.target"], initTable[string, Table[string, string]](), log)
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "ok.service"
  content = "[Service]\nExecStart=/bin/true\n"
}
""")
    discard p
    check releaseStarts(p, ["ok.service", "bad.service"], ["ok.service"],
      refused, ["ok.service"], ["bad.service", "ok.target"], [], host).len == 0
    check "bad.service" notin log[]
    check "ok.target" in log[]

  test "a passed instance does not lift the hold its refused sibling shares":
    let n = "zz-repro-carried-check-hold.conf"
    check liftableHolds(["foo@b.service", "ok.service"], ["foo@a.service"], n) ==
      @[holdPath("ok.service", n)]
    check liftableHolds(["foo@b.service"], ["foo@a.service"], n,
      PersistentUnitDir).len == 0
    check liftableHolds(["foo@b.service", "foo@c.service"], [], n) ==
      @[holdPath("foo@b.service", n)]

  test "a refusal no unit is named in holds every unit":
    check refusedUnits(["a.service", "b.service"],
      ["carried state reached after the reload (decided again after the reload)"]) ==
      @["a.service", "b.service"]
    check refusedUnits(["a.service"], []).len == 0

  test "a template is refused by its instances' problems (decision 135)":
    # liveReachProblems names a template's instances, never the template.
    let problems = ["floored unit: foo@b.service as systemd loaded it runs as root"]
    check refusedUnits(["foo@.service", "ok.service"], problems) ==
      @["foo@.service"]
    # A unit whose name merely starts like the stem is not the template's.
    check refusedUnits(["foo@.service", "ok.service"],
      ["floored unit: foobar.service as systemd loaded it runs as root"]) ==
      @["foo@.service", "ok.service"]

  test "a passed template starts its instances that ran before, never its name (decision 135)":
    var log = new seq[string]
    let host = fakeHost(@["t.target"], initTable[string, Table[string, string]](), log)
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "foo@.service"
  content = "[Service]\nExecStart=/bin/true\n"
  enabled = false
}
""")
    check releaseStarts(p, ["foo@.service"], ["foo@.service"], [],
      ["foo@a.service", "foo@b.service", "bar.service"],
      ["foo@.service", "t.target"], [], host).len == 0
    check log[] == @["foo@a.service", "foo@b.service", "t.target"]
    # Refused: none of its instances start.
    log[].setLen(0)
    check releaseStarts(p, ["foo@.service"], [], ["foo@.service"],
      ["foo@a.service"], [], [], host).len == 0
    check log[].len == 0

  test "a failed start is reported, and the others still start":
    var log = new seq[string]
    let host = fakeHost(@["a.target", "b.target"], initTable[string, Table[string, string]](), log, "a.target")
    let probs = releaseStarts(parseSystemProfile(""), ["s.service"], ["s.service"],
      [], [], ["a.target", "b.target"], [], host)
    check log[] == @["a.target", "b.target"]
    check probs.len == 1 and "a.target" in probs[0]

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

suite "held units' triggers, the triggers to fire again, and requirers of a refused unit (decisions 151-153)":
  # The release's systemd reads and starts are closures (``LiveHost``), so
  # the order and the choice of what is stopped and started is tested
  # without a running systemd; the VM cases run the real manager.
  proc host9(active: seq[string]; shows: Table[string, Table[string, string]];
             log: ref seq[string]): LiveHost =
    let started = new seq[string]
    LiveHost(
      isActive: proc (u: string): bool = u in active or u in started[],
      show: proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "no unit " & u)
        result = shows[u]
        if u in started[]: result["ActiveState"] = "active",
      start: proc (u: string): tuple[ok: bool, output: string] =
        log[].add("start " & u)
        started[].add(u)
        (true, ""),
      stop: proc (u: string): tuple[ok: bool, output: string] =
        log[].add("stop " & u)
        (true, ""),
      resetFailed: proc (u: string) = log[].add("reset-failed " & u))

  test "decision 151: a held unit's loaded triggers are read from its TriggeredBy=":
    let shows = {
      "a.service": {"TriggeredBy": "a.socket a.path foo.target"}.toTable,
      "tpl@x.service": {"TriggeredBy": "tpl@x.timer"}.toTable}.toTable
    var log = new seq[string]
    check loadedTriggersOf(["a.service", "tpl@x.service", "gone.service"],
      host9(@[], shows, log)) == @["a.socket", "a.path", "tpl@x.timer"]

  test "decision 151: the profile's own triggers of held units, an instance's by its template":
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "x.socket"
  content = "[Socket]\nListenStream=/run/x\n"
}
systemd.systemUnit {
  name = "bk.timer"
  content = "[Timer]
OnActiveSec=1
Unit=bk@daily.service
"
}
systemd.systemUnit {
  name = "other.timer"
  content = "[Timer]
OnActiveSec=1
"
}
""")
    check profileTriggersOf(p, ["x.service", "bk@.service"]) == @["x.socket", "bk.timer"]

  test "decision 151: a stopped trigger comes back with reset-failed, but a refused unit's and an unloaded one":
    let shows = {
      "a.socket": {"LoadState": "loaded"}.toTable,
      "gone.path": {"LoadState": "not-found"}.toTable,
      "r.socket": {"LoadState": "loaded"}.toTable}.toTable
    var log = new seq[string]
    check triggerRestarts(["a.socket", "gone.path", "r.socket"], ["r.socket"],
      host9(@[], shows, log)).len == 0
    check log[] == @["reset-failed a.socket", "start a.socket"]

  test "decision 151: a trigger whose unit runs is not stopped, unless the apply restarts that unit":
    let shows = {
      "run.socket": {"Triggers": "run.service"}.toTable,
      "idle.socket": {"Triggers": "idle.service"}.toTable,
      "re.path": {"Triggers": "re.service"}.toTable,
      "off.timer": {"Triggers": "off.service"}.toTable}.toTable
    var log = new seq[string]
    let host = host9(@["run.socket", "run.service", "idle.socket", "re.path",
                       "re.service"], shows, log)
    # run.service serves its own socket (with Accept=no it holds the
    # listening descriptor: a stop and start of the socket could not bind
    # again); idle.service does not run; re.service runs but is restarted
    # under the hold; off.timer is not active.
    check triggersToStop(["run.socket", "idle.socket", "re.path", "off.timer"],
      ["re.service"], host) == @["idle.socket", "re.path"]

  test "decision 151: a socket whose RemainAfterExit=yes oneshot service has run is left alone":
    # reprobuild-pm issue 2026-11-15-addon-switch-a-socket-stopped-for-a-hold-
    # while-its-service-runs-cannot-start-again (A9's reapply gate): the
    # oneshot ran and exited, and systemd reports it ActiveState=active, so
    # its socket cannot fire at the hold; stopped, it could not start again
    # ("Socket service a9r-sk.service already active, refusing").
    let shows = {
      "a9r-sk.socket": {"Triggers": "a9r-sk.service"}.toTable,
      "a9r-sk.service": {"ActiveState": "active", "SubState": "exited",
                         "Type": "oneshot", "RemainAfterExit": "yes"}.toTable}.toTable
    var log = new seq[string]
    let host = LiveHost(
      isActive: proc (u: string): bool =
        u == "a9r-sk.socket" or shows[u].getOrDefault("ActiveState") == "active",
      show: proc (u: string): Table[string, string] = shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    check triggersToStop(["a9r-sk.socket"], [], host).len == 0
    # Restarted under the hold, it can fire: the socket is stopped then.
    check triggersToStop(["a9r-sk.socket"], ["a9r-sk.service"], host) ==
      @["a9r-sk.socket"]

  test "decision 152: the triggers looked at are every held unit's, not only the drivers' starts":
    check fireSources(["d.timer"], ["u.timer", "d.timer"]) == @["d.timer", "u.timer"]

  test "decision 152: an instance timer of a judged template that fired under the hold":
    let heldShow = {"ConditionResult": "no", "ConditionTimestampMonotonic": "5000"}.toTable
    var shows = {"tpl@daily.timer": {"Triggers": "tpl@daily.service"}.toTable}.toTable
    shows["tpl@daily.service"] = heldShow
    var log = new seq[string]
    check firedUnderHold(["tpl@daily.timer"], ["tpl@.service"], [],
      host9(@["tpl@daily.timer"], shows, log), 1000) == @["tpl@daily.service"]

  test "decision 153: a unit that requires or binds to a refused unit stays held, transitively":
    let shows = {
      "dep.service": {"Requires": "bad.service network.target"}.toTable,
      "dep2.service": {"BindsTo": "dep.service"}.toTable,
      "inst.service": {"Requires": "tpl@a.service"}.toTable,
      "free.service": {"Requires": "other.service", "Wants": "bad.service"}.toTable}.toTable
    var log = new seq[string]
    let held = requiringRefused(
      ["dep2.service", "dep.service", "inst.service", "free.service"],
      ["bad.service", "tpl@.service"], host9(@[], shows, log))
    var units: seq[string]
    for (u, because) in held: units.add(u & " <- " & because)
    check units.len == 3
    check "dep.service <- bad.service" in units
    check "dep2.service <- dep.service" in units
    check "inst.service <- tpl@a.service" in units

suite "a trigger that cannot start again leaves the host pending (decision 160)":
  # A state directory of the test's own (the real filesystem); systemd is a
  # closure, so a start that fails can be staged without a host.
  test "recover starts each recorded trigger again; one that still fails stays recorded":
    let dir = getTempDir() / ("t155-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeTriggersToRestart(dir, ["a.socket", "b.socket"])
    check hasTriggersToRestart(dir)
    var log = new seq[string]
    let host = simHost(log, failing = @["b.socket"])
    let r = retryTriggerRestarts(dir, host)
    check not r.ok
    check log[] == @["reset-failed a.socket", "start a.socket",
                     "reset-failed b.socket", "start b.socket"]
    check readTriggersToRestart(dir) == @["b.socket"]
    check "trigger a.socket started again" in r.lines
    let again = retryTriggerRestarts(dir, simHost(new seq[string]))
    check again.ok
    check not hasTriggersToRestart(dir)

  test "the pending-switch guard refuses while a recorded trigger does not start":
    let dir = getTempDir() / ("t155g-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeTriggersToRestart(dir, ["b.socket"])
    let refused = checkPendingSwitches(dir,
      proc (d: string): RecoveryOutcome {.closure, gcsafe.} =
        RecoveryOutcome(resolved: false, lines: @["b.socket did not start"]),
      pointer = dir / "no-pointer")
    check not refused.ok
    check "b.socket did not start" in refused.why
    let passes = checkPendingSwitches(dir,
      proc (d: string): RecoveryOutcome {.closure, gcsafe.} =
        RecoveryOutcome(resolved: true),
      pointer = dir / "no-pointer")
    check passes.ok

  test "decision 160: once a marker is resolved, recover starts the recorded triggers too":
    let dir = getTempDir() / ("t160r-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeTriggersToRestart(dir, ["a.socket"])
    let host = simHost(new seq[string])
    let r = afterRecovery(RecoveryOutcome(resolved: true,
      lines: @["replayed the switch to completion"]), dir, host)
    check r.resolved
    check "trigger a.socket started again" in r.lines
    check not hasTriggersToRestart(dir)

  test "decision 160: a trigger the revert recorded is started by none of step 7's sources":
    # The same trigger as a planned start, as a trigger step 2 paused, and
    # as a unit planned as running that is down: step 7 starts it from none.
    var assume = initHashSet[string]()
    assume.incl("t.socket")
    assume.incl("other.service")
    let inputs = step7Inputs(
      @[Transition(unit: "t.socket", verb: tvStart, reason: "enabled"),
        Transition(unit: "u.service", verb: tvRestart, reason: "changed")],
      @["t.socket", "p.socket"], assume, ["t.socket"])
    var units: seq[string]
    for tr in inputs.transitions: units.add(tr.unit)
    check units == @["u.service"]
    check inputs.paused == @["p.socket"]
    check "t.socket" notin inputs.assumeActive
    check "other.service" in inputs.assumeActive
    # Nothing excluded (not a revert): everything stays.
    let same = step7Inputs(@[Transition(unit: "t.socket", verb: tvStart,
      reason: "enabled")], @["t.socket"], assume, [])
    check same.transitions.len == 1 and same.paused == @["t.socket"] and
      "t.socket" in same.assumeActive

suite "the triggers of held units, and a revert's record of them (A13 review round 10)":
  # The reviewer's probe scenarios (A13 review round 10) as tests. systemd is
  # a closure (``LiveHost``) whose answers change as the scenario goes on;
  # the records are files in a state directory of the test's own.
  proc scratch(tag: string): string =
    result = getTempDir() / ("t-r10-" & tag & "-" & $getCurrentProcessId())
    removeDir(result)
    createDir(result)

  proc liveHost10(active: ref seq[string];
                  shows: ref Table[string, Table[string, string]];
                  log: ref seq[string]; failing: seq[string] = @[]): LiveHost =
    LiveHost(
      isActive: proc (u: string): bool = u in active[],
      show: proc (u: string): Table[string, string] =
        result = shows[].getOrDefault(u, {"LoadState": "loaded"}.toTable)
        result["ActiveState"] = (if u in active[]: "active" else: "inactive"),
      start: proc (u: string): tuple[ok: bool, output: string] =
        log[].add("start " & u)
        if u in failing: return (false, "Job failed")
        if u notin active[]: active[].add(u)
        (true, ""),
      stop: proc (u: string): tuple[ok: bool, output: string] =
        log[].add("stop " & u)
        (true, ""),
      resetFailed: proc (u: string) = log[].add("reset-failed " & u))

  const SockGen = """systemd.systemUnit {
  name = "s.socket"
  content = "[Socket]\nListenStream=/run/s\n"
}
systemd.systemUnit {
  name = "s.service"
  content = "[Service]\nExecStart=/bin/true\n"
}
systemd.systemUnit {
  name = "other.service"
  content = "[Service]\nExecStart=/bin/true\n"
}
"""

  proc entryFor(p: SystemProfile; t: string; units: seq[string]): TriggerRestartEntry =
    result = TriggerRestartEntry(unit: t)
    for u in @[t] & units:
      result.rendered.add((unit: u, digest: renderedUnitDigest(p, u)))

  test "decision 160: an add-on switch is refused before its first write while a recorded trigger does not start":
    # Finding 1: the infra apply's guard leaves a switch's own marker to
    # the switch, so the switch checks the record itself.
    let dir = scratch("f1")
    defer: removeDir(dir)
    let g = parseSystemProfile(SockGen)
    writeTriggerRestartEntries(dir, [entryFor(g, "s.socket", @["s.service"])])
    var active = new seq[string]
    var shows = new Table[string, Table[string, string]]
    shows[]["s.socket"] = {"LoadState": "loaded"}.toTable
    var log = new seq[string]
    let why = switchTriggerRecordRefusal(dir, g,
      liveHost10(active, shows, log, failing = @["s.socket"]))
    check "the host is pending" in why
    check "s.socket" in why
    check readTriggersToRestart(dir) == @["s.socket"]
    # Once the trigger starts, the same switch goes ahead and the record
    # is gone.
    check switchTriggerRecordRefusal(dir, g, liveHost10(active, shows, log)) == ""
    check not hasTriggersToRestart(dir)

  test "the fixing apply: a generation that changes or removes the recorded trigger or its unit goes through, any other is refused":
    let dir = scratch("f9")
    defer: removeDir(dir)
    let g = parseSystemProfile(SockGen)
    let e = entryFor(g, "s.socket", @["s.service"])
    var active = new seq[string]
    var shows = new Table[string, Table[string, string]]
    shows[]["s.socket"] = {"LoadState": "loaded"}.toTable
    var log = new seq[string]
    let host = liveHost10(active, shows, log, failing = @["s.socket"])
    let sockChanged = parseSystemProfile(SockGen.replace("ListenStream=/run/s",
                                                        "ListenStream=/run/s2"))
    let unitChanged = parseSystemProfile(SockGen.replace(
      "name = \"s.service\"\n  content = \"[Service]\\nExecStart=/bin/true",
      "name = \"s.service\"\n  content = \"[Service]\\nExecStart=/bin/false"))
    let removed = parseSystemProfile("""systemd.systemUnit {
  name = "other.service"
  content = "[Service]\nExecStart=/bin/true\n"
}
""")
    let unrelated = parseSystemProfile(SockGen.replace(
      "name = \"other.service\"\n  content = \"[Service]\\nExecStart=/bin/true",
      "name = \"other.service\"\n  content = \"[Service]\\nExecStart=/bin/false"))
    check renderedUnitDigest(unitChanged, "s.service") !=
      renderedUnitDigest(g, "s.service")
    check renderedUnitDigest(unrelated, "s.service") ==
      renderedUnitDigest(g, "s.service")
    for (name, target, goes) in [("the same generation", g, false),
                                 ("another unit changed", unrelated, false),
                                 ("the trigger changed", sockChanged, true),
                                 ("its unit changed", unitChanged, true),
                                 ("both removed", removed, true)]:
      writeTriggerRestartEntries(dir, [e, TriggerRestartEntry(unit: "d.service",
        dependantOf: "s.socket")])
      let why = switchTriggerRecordRefusal(dir, target, host)
      checkpoint name & ": " & why
      check (why == "") == goes
      # The full apply's guard decides the same way.
      let guard = checkPendingSwitches(dir,
        proc (d: string): RecoveryOutcome {.closure, gcsafe.} =
          RecoveryOutcome(resolved: false, lines: @["s.socket did not start"]),
        pointer = dir / "no-pointer", target = target, hasTarget = true)
      check guard.ok == goes
      # The commit clears what its generation resolves, the dependant with
      # its trigger, and nothing else.
      let cleared = clearResolvedRestartEntries(dir, target)
      if goes:
        check cleared == @["s.socket", "d.service"]
        check not hasTriggersToRestart(dir)
      else:
        check cleared.len == 0
        check readTriggersToRestart(dir) == @["s.socket", "d.service"]
    # An apply that names no generation (the guard of a switch's own infra
    # apply) is never the fixing one.
    writeTriggerRestartEntries(dir, [e])
    check not checkPendingSwitches(dir,
      proc (d: string): RecoveryOutcome {.closure, gcsafe.} =
        RecoveryOutcome(resolved: false, lines: @["no"]),
      pointer = dir / "no-pointer").ok

  test "decision 151: a trigger left alone whose Accept=no service exits during the hold is started again at release":
    # Finding 2: the socket's service ran, so the hold left the socket
    # alone; the service exited during the hold, the next connection fired
    # the socket at the held service, and the socket failed with it.
    var active = new seq[string]
    active[] = @["s.socket", "s.service"]
    var shows = new Table[string, Table[string, string]]
    shows[]["s.socket"] = {"Triggers": "s.service", "LoadState": "loaded"}.toTable
    var log = new seq[string]
    let host = liveHost10(active, shows, log)
    let remembered = rememberedTriggers(["s.socket"], host)
    let stopped = triggersToStop(["s.socket"], [], host)
    check remembered == @["s.socket"]
    check stopped.len == 0
    # During the hold: the service exits, the socket fails.
    active[] = @[]
    let release = triggersToRelease(remembered, stopped, [], ["s.socket"])
    check release == @["s.socket"]
    check triggerRestarts(release, [], host).len == 0
    check log[] == @["reset-failed s.socket", "start s.socket"]
    # One still up at release needs nothing.
    log[].setLen(0)
    check triggerRestarts(release, [], host).len == 0
    check log[].len == 0

  test "decision 151: a running socket the generation re-points at a held unit is stopped for the hold":
    # Finding 6: systemd still reports the old, running target; after the
    # drivers' reload it fires at the held one.
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "s.socket"
  content = "[Socket]
ListenStream=/run/s
Service=new.service
"
}
""")
    var active = new seq[string]
    active[] = @["s.socket", "old.service"]
    var shows = new Table[string, Table[string, string]]
    shows[]["s.socket"] = {"Triggers": "old.service"}.toTable
    var log = new seq[string]
    let host = liveHost10(active, shows, log)
    check triggersToStop(["s.socket"], [], host).len == 0
    check triggersToStop(["s.socket"], [], host, triggerTargets(p)) == @["s.socket"]

  test "decision 152: a held template's idle instance timer is found by asking systemd":
    # Finding 3: tpl@daily.timer is neither running nor named by the
    # generation; the host lists it.
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "tpl@.service"
  content = "[Service]\nExecStart=/bin/true\n"
}
systemd.systemUnit {
  name = "tpl@.timer"
  content = "[Timer]\nOnCalendar=daily\n"
}
""")
    let loaded = @["tpl@daily.timer", "tpl@weekly.service", "other@x.timer",
                   "tpl@.timer"]
    var asked = new seq[string]
    let lister = proc (pattern: string): seq[string] =
      asked[].add(pattern)
      let star = pattern.find('*')
      for n in loaded:
        if n.startsWith(pattern[0 ..< star]) and n.endsWith(pattern[star + 1 .. ^1]):
          result.add(n)
    check templateTriggerInstances(p, ["tpl@.service"], lister) == @["tpl@daily.timer"]
    check "tpl@*.timer" in asked[]
    var active = new seq[string]
    var shows = new Table[string, Table[string, string]]
    var log = new seq[string]
    let held = heldTriggersOf(p.resources, ["tpl@.service"],
                              liveHost10(active, shows, log), lister)
    check "tpl@daily.timer" in held

  test "decision 160: a crash between the revert's two records leaves the trigger on the restart record":
    # Finding 4: the restart record is written before the held record
    # drops the trigger.
    let dir = scratch("f4")
    defer: removeDir(dir)
    writeHeldTriggers(dir, ["a.socket", "b.socket"])
    expect IOError:
      recordUnstartableTriggers(dir, ["b.socket"],
        [TriggerRestartEntry(unit: "a.socket")],
        proc () = raise newException(IOError, "crash between the writes"))
    check "a.socket" in readTriggersToRestart(dir)
    # Uninterrupted: the held record drops it once it is on the other.
    recordUnstartableTriggers(dir, ["b.socket"],
                              [TriggerRestartEntry(unit: "a.socket")])
    check readHeldTriggers(dir) == @["b.socket"]
    check readTriggersToRestart(dir) == @["a.socket"]

  test "decision 151: a full apply that dies during its hold leaves its triggers on record for the next apply":
    # Finding 5: the record is written before any trigger is stopped, and
    # the next apply (or recover) starts them again.
    let dir = scratch("f5")
    defer: removeDir(dir)
    recordLiveCheckTriggers(dir, ["s.socket", "t.timer"])
    # ... the apply raises here ...
    var active = new seq[string]
    var shows = new Table[string, Table[string, string]]
    shows[]["s.socket"] = {"LoadState": "loaded"}.toTable
    shows[]["t.timer"] = {"LoadState": "loaded"}.toTable
    var log = new seq[string]
    check restartRecordedLiveCheckTriggers(dir,
      liveHost10(active, shows, log, failing = @["t.timer"])).len == 1
    check "start s.socket" in log[]
    check readLiveCheckTriggers(dir) == @["t.timer"]
    check restartRecordedLiveCheckTriggers(dir,
      liveHost10(active, shows, log)).len == 0
    check not fileExists(dir / LiveCheckTriggersFile)

  test "leave dependants out: a unit that requires, binds to or takes its sockets from a recorded trigger is left out and started after it":
    # systemd's effective dependencies, as ``systemctl show`` reports them
    # (the reverse properties; a service's ``Sockets=`` is the socket's
    # ``Triggers=``; ``Wants=`` is no dependency that fails a start).
    let shows = {
      "t.socket": {"RequiredBy": "dep.service", "Triggers": "sk.service",
                   "WantedBy": "free.service"}.toTable,
      "dep.service": {"BoundBy": "dep2.service"}.toTable,
      "dep2.service": initTable[string, string](),
      "sk.service": initTable[string, string](),
      "free.service": initTable[string, string]()}.toTable
    let deps = step7Dependants(["dep2.service", "free.service", "dep.service",
                                "sk.service"], ["t.socket"],
      proc (u: string): Table[string, string] = shows[u])
    var names: seq[string]
    for (u, root) in deps:
      check root == "t.socket"
      names.add(u)
    check names.len == 3
    check names.find("dep.service") < names.find("dep2.service")
    check "sk.service" in names and "free.service" notin names
    # Recover starts the trigger, then its dependants in recorded order; a
    # trigger that still fails keeps its dependants untried.
    let dir = scratch("f7")
    defer: removeDir(dir)
    var entries = @[TriggerRestartEntry(unit: "t.socket")]
    for u in names: entries.add(TriggerRestartEntry(unit: u, dependantOf: "t.socket"))
    writeTriggerRestartEntries(dir, entries)
    var active = new seq[string]
    var shows2 = new Table[string, Table[string, string]]
    shows2[]["t.socket"] = {"LoadState": "loaded"}.toTable
    var log = new seq[string]
    check not retryTriggerRestarts(dir,
      liveHost10(active, shows2, log, failing = @["t.socket"])).ok
    check log[] == @["reset-failed t.socket", "start t.socket"]
    check readTriggersToRestart(dir).len == 4
    log[].setLen(0)
    check retryTriggerRestarts(dir, liveHost10(active, shows2, log)).ok
    var starts: seq[string]
    for l in log[]:
      if l.startsWith("start "): starts.add(l[6 .. ^1])
    check starts == @["t.socket"] & names
    check not hasTriggersToRestart(dir)

  test "decision 153: a template that requires a refused unit is judged through its instances":
    # Finding 8: systemd refuses to show a template by name.
    var shows = initTable[string, Table[string, string]]()
    shows["tpl@a.service"] = {"Requires": "bad.service"}.toTable
    shows["tpl@repro-addon-observe.service"] = {"Requires": ""}.toTable
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "refused: " & u)
        shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    let held = requiringRefused(["tpl@.service", "ok.service"], ["bad.service"],
      host, proc (t: string): seq[string] = @["tpl@a.service"])
    check held.len == 1
    check held[0].unit == "tpl@.service" and held[0].because == "bad.service"


suite "every requirer of a refused unit stays held (decision 153, A13 review round 10)":
  test "decision 153: the generation's units that require a judged unit, judged or not, transitively":
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "grp.target"
  content = "[Unit]
Requires=gen.service
"
}
systemd.systemUnit {
  name = "bound.service"
  content = "[Unit]
BindsTo=grp.target
[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "reset.service"
  content = "[Unit]
Requires=gen.service
Requires=
[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "wants.service"
  content = "[Unit]
Wants=gen.service
[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "dropped.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemDropIn {
  unit = "dropped.service"
  name = "req"
  content = "[Unit]
Requires=gen.service
"
}
""")
    let reqs = profileRequirersOf(p, ["gen.service"])
    # A target is followed through to its requirers, never held itself
    # (the owner decision "never hold .target units", A13 review round 12).
    check "grp.target" notin reqs
    check "bound.service" in reqs
    check "dropped.service" in reqs
    # An empty Requires= is no reset (systemd's config_parse_unit_deps;
    # A13 review round 11, M4, measured on systemd 260).
    check "reset.service" in reqs
    check "wants.service" notin reqs        # Wants= is not a requirement
    check "gen.service" notin reqs
    # Read live after the reload, an unjudged requirer of a refused unit
    # stays held with it (``requiringRefused`` over the passed units and
    # these requirers).
    let shows = {"grp.target": {"Requires": "gen.service"}.toTable,
                 "bound.service": {"BindsTo": "grp.target"}.toTable}.toTable
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "no unit " & u)
        shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    var held: seq[string]
    for (u, because) in requiringRefused(reqs, ["gen.service"], host):
      held.add(u)
    # bound.service binds to grp.target, which requires the refused unit:
    # found through the target, which is not held.
    check "bound.service" in held and "grp.target" notin held

  test "decision 170: a generation that resolves only some of the recorded triggers is refused":
    let dir = getTempDir() / ("t-r10-partial-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let g = parseSystemProfile("""systemd.systemUnit {
  name = "a.socket"
  content = "[Socket]\nListenStream=/run/a\n"
}
systemd.systemUnit {
  name = "b.socket"
  content = "[Socket]\nListenStream=/run/b\n"
}
""")
    var ea = TriggerRestartEntry(unit: "a.socket")
    ea.rendered.add((unit: "a.socket", digest: renderedUnitDigest(g, "a.socket")))
    var eb = TriggerRestartEntry(unit: "b.socket")
    eb.rendered.add((unit: "b.socket", digest: renderedUnitDigest(g, "b.socket")))
    writeTriggerRestartEntries(dir, [ea, eb])
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] = {"LoadState": "loaded"}.toTable,
      start: proc (u: string): tuple[ok: bool, output: string] = (false, "Job failed"))
    let onlyA = parseSystemProfile("""systemd.systemUnit {
  name = "a.socket"
  content = "[Socket]\nListenStream=/run/a2\n"
}
systemd.systemUnit {
  name = "b.socket"
  content = "[Socket]\nListenStream=/run/b\n"
}
""")
    let why = switchTriggerRecordRefusal(dir, onlyA, host)
    check "b.socket" in why
    check "a.socket" notin why.split("could not")[0]
    check readTriggersToRestart(dir) == @["a.socket", "b.socket"]


suite "a restart is confirmed by systemd, and the records of triggers hold (A13 review round 11)":
  # The reviewer's round-11 probes (P1-P6) as tests. The host is
  # ``simHost``: a unit with a condition hold starts with exit 0 and stays
  # inactive, as systemd does; no fake reports a start as running unless
  # the unit was really started.
  proc scratch11(tag: string): string =
    result = getTempDir() / ("t-r11-" & tag & "-" & $getCurrentProcessId())
    removeDir(result)
    createDir(result)

  const Gen11 = """systemd.systemUnit {
  name = "s.socket"
  content = "[Socket]
ListenStream=/run/s
"
}
systemd.systemUnit {
  name = "s.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "dep.service"
  content = "[Unit]
Requires=s.socket
[Service]
ExecStart=/bin/true
"
}
"""

  proc entry11(p: SystemProfile; t: string; units: seq[string];
               of0 = ""): TriggerRestartEntry =
    result = TriggerRestartEntry(unit: t, dependantOf: of0)
    for u in @[t] & units:
      result.rendered.add((unit: u, digest: renderedUnitDigest(p, u)))

  test "H1: a start a condition hold skips exits 0 and is not taken as a start":
    var log = new seq[string]
    let host = simHost(log, skipped = @["s.socket"])
    let r = startConfirmed(host, "s.socket", mustStayActive = true)
    check not r.ok
    check "ConditionResult=no" in r.why
    check triggerRestarts(["s.socket"], [], host).len == 1
    check startConfirmed(simHost(log), "s.socket", mustStayActive = true).ok

  test "H1: a recorded live-check trigger whose start a stale hold skips stays on record":
    # Probe P5: the next apply's (or recover's) restart under the dead
    # apply's hold exits 0; the record must keep the trigger.
    let dir = scratch11("p5")
    defer: removeDir(dir)
    recordLiveCheckTriggers(dir, ["s.socket"])
    var log = new seq[string]
    let probs = restartRecordedLiveCheckTriggers(dir, simHost(log, skipped = @["s.socket"]))
    check probs.len == 1
    check readLiveCheckTriggers(dir) == @["s.socket"]
    # And a recorded dependant whose start is skipped stays recorded.
    let g = parseSystemProfile(Gen11)
    writeTriggerRestartEntries(dir, [entry11(g, "s.socket", @["s.service"]),
      entry11(g, "dep.service", @[], "s.socket")])
    check not retryTriggerRestarts(dir, simHost(log, skipped = @["dep.service"])).ok
    check readTriggersToRestart(dir) == @["dep.service"]

  test "M4: an empty Requires= in a drop-in does not reset the requirement":
    # Probe P1.
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "x.service"
  content = "[Unit]
Requires=gen.service
[Service]
ExecStart=/bin/true
"
}
systemd.systemDropIn {
  unit = "x.service"
  name = "empty"
  content = "[Unit]
Requires=
"
}
""")
    check profileRequirersOf(p, ["gen.service"]) == @["x.service"]
    check unitRequirements(["[Unit]\nRequires=a.service\n", "[Unit]\nRequires=\nBindsTo=b.service\n"]) ==
      @["a.service", "b.service"]

  test "M3: a template that requires a judged unit is held as a requirer":
    # Probe P2: held as the template, judged through its instances.
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "tpl@.service"
  content = "[Unit]
Requires=gen.service
[Service]
ExecStart=/bin/true
"
}
""")
    check profileRequirersOf(p, ["gen.service"]) == @["tpl@.service"]

  test "decision 171: the requirers systemd's effective dependencies name are found":
    # RequiredBy=/BoundBy= cover a .requires/ link, an [Install]
    # RequiredBy= and a host drop-in, which no file of the generation says.
    var shows = initTable[string, Table[string, string]]()
    shows["gen.service"] = {"RequiredBy": "link.target", "BoundBy": "bound.service"}.toTable
    shows["link.target"] = {"RequiredBy": "outer.service"}.toTable
    shows["bound.service"] = initTable[string, string]()
    shows["outer.service"] = initTable[string, string]()
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "no unit " & u)
        shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    # Read before anything is written (the layer ``requirers-from-files-
    # only`` turns off): no file of this generation names them.
    let found = preWriteRequirers(SystemProfile(), ["gen.service"], host)
    # link.target is followed through to outer.service, and not held
    # itself ("never hold .target units", A13 review round 12).
    check found.len == 2
    check "link.target" notin found and "bound.service" in found and
      "outer.service" in found

  test "decision 171: an essential unit that would be held refuses the apply":
    check essentialHeld(["ssh.service", "getty@tty6.service", "app.service",
                         "repro-agent-fetch.timer"]) ==
      @["ssh.service", "getty@tty6.service", "repro-agent-fetch.timer"]
    check essentialHeld(["app.service", "x@y.service"]).len == 0
    # Every unit the management path names (§7.5) is essential too, so the
    # two lists cannot drift apart.
    for u in ManagementPathUnits:
      if u.endsWith(".slice") or u.endsWith(".scope") or u == "user-.slice":
        continue
      checkpoint u
      check isEssentialUnit(u) or isEssentialUnit(u.replace("@.", "@x."))

  test "M1: a recorded dependant still failing blocks, as a trigger does":
    # Probe P3: the trigger starts, the dependant does not; the dependant
    # is an orphan on record and blocks every switch and full apply that
    # does not resolve it by its own renderings.
    let dir = scratch11("p3")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen11)
    writeTriggerRestartEntries(dir, [entry11(g, "s.socket", @["s.service"]),
      entry11(g, "dep.service", @[], "s.socket")])
    var log = new seq[string]
    let host = simHost(log, failing = @["dep.service"])
    let why = switchTriggerRecordRefusal(dir, g, host)
    check "dep.service" in why
    check readTriggersToRestart(dir) == @["dep.service"]
    check not checkPendingSwitches(dir,
      proc (d: string): RecoveryOutcome {.closure, gcsafe.} =
        RecoveryOutcome(resolved: false, lines: @["dep.service did not start"]),
      pointer = dir / "no-pointer", target = g, hasTarget = true).ok
    check clearResolvedRestartEntries(dir, g).len == 0
    # A generation that changes the dependant resolves it.
    let depChanged = parseSystemProfile(Gen11.replace("Requires=s.socket\n[Service]\nExecStart=/bin/true",
                                                     "Requires=s.socket\n[Service]\nExecStart=/bin/false"))
    check switchTriggerRecordRefusal(dir, depChanged, host) == ""
    check clearResolvedRestartEntries(dir, depChanged) == @["dep.service"]

  test "the fixing switch starts what it resolves, each confirmed, and fails when one does not start":
    # The owner decision "the fixing switch starts them" (A13 review round
    # 11, H2), and probe P6: a comment-only change resolves the entry but
    # must then start the trigger.
    let dir = scratch11("h2")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen11)
    let entries = [entry11(g, "s.socket", @["s.service"]),
                   entry11(g, "dep.service", @[], "s.socket")]
    let comment = parseSystemProfile(Gen11.replace("ListenStream=/run/s\n",
                                                  "ListenStream=/run/s\n# cosmetic\n"))
    check restartEntryResolvedBy(entries[0], comment)
    writeTriggerRestartEntries(dir, entries)
    var log = new seq[string]
    check startResolvedRestartEntries(dir, comment, simHost(log)).len == 0
    check log[].filterIt(it.startsWith("start ")) ==
      @["start s.socket", "start dep.service"]
    # Still blocked: the trigger's start is skipped -- a failure, and the
    # record keeps both entries for the revert.
    log[].setLen(0)
    let probs = startResolvedRestartEntries(dir, comment,
                                            simHost(log, skipped = @["s.socket"]))
    # The trigger's failure, and its dependant not attempted (round 13, L4).
    check probs.len == 2
    check "s.socket" in probs[0]
    check "dep.service not attempted" in probs[1]
    check "start dep.service" notin log[]
    check readTriggersToRestart(dir) == @["s.socket", "dep.service"]
    # A generation that resolves nothing starts nothing.
    log[].setLen(0)
    check startResolvedRestartEntries(dir, g, simHost(log)).len == 0
    check log[].len == 0

  test "M2: recover changes the records of triggers only under the host apply lock":
    let dir = scratch11("m2")
    defer: removeDir(dir)
    let lockPath = dir / "host-apply.lock"
    putEnv(HostApplyLockEnvVar, lockPath)
    putEnv(HostApplyLockWaitEnvVar, "1")
    defer:
      delEnv(HostApplyLockEnvVar)
      delEnv(HostApplyLockWaitEnvVar)
    writeTriggersToRestart(dir, ["s.socket"])
    # Another process -- an apply changing the host -- holds the lock.
    let holder = startProcess("flock", args = ["-x", lockPath, "sleep", "3"],
                              options = {poUsePath})
    defer:
      if holder.running: holder.terminate()
      discard holder.waitForExit()
      holder.close()
    var waited = 0
    while waited < 50 and not fileExists(lockPath):
      sleep(100)
      inc waited
    sleep(300)
    var log = new seq[string]
    let r = repairTriggerRecords(dir, simHost(log))
    check not r.resolved
    check log[].len == 0
    check readTriggersToRestart(dir) == @["s.socket"]
    discard holder.waitForExit()
    # Once it is free, the repair runs.
    let r2 = repairTriggerRecords(dir, simHost(log))
    check r2.resolved
    check not hasTriggersToRestart(dir)

  test "L1: a service that takes its sockets from a recorded trigger is left out with it":
    # systemd shows ``Sockets=`` on the socket as ``Triggers=`` the
    # service; ``RequiredBy=``/``BoundBy=`` name the rest.
    var shows = initTable[string, Table[string, string]]()
    shows["t.socket"] = {"Triggers": "sk.service", "RequiredBy": "dep.service"}.toTable
    shows["dep.service"] = {"BoundBy": "dep2.service"}.toTable
    shows["sk.service"] = initTable[string, string]()
    shows["dep2.service"] = initTable[string, string]()
    let deps = step7Dependants(["dep2.service", "free.service", "dep.service",
                                "sk.service"], ["t.socket"],
      proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "no unit " & u)
        shows[u])
    var names: seq[string]
    for (u, root) in deps:
      check root == "t.socket"
      names.add(u)
    check names.len == 3
    check "sk.service" in names and "free.service" notin names
    check names.find("dep.service") < names.find("dep2.service")


  test "decision 177: a requirer systemd names only after the reload is held then, an essential one reported":
    # The post-reload layer (``post-reload-requirers-released`` turns off
    # only it): a unit the generation's writes made a requirer of a refused
    # unit, which no layer before the writes could name.
    var shows = initTable[string, Table[string, string]]()
    shows["gen.service"] = {"RequiredBy": "req.service late.service sshd.service"}.toTable
    shows["req.service"] = initTable[string, string]()
    shows["late.service"] = initTable[string, string]()
    shows["sshd.service"] = initTable[string, string]()
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        if u notin shows: raise newException(OSError, "no unit " & u)
        shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    let late = postReloadRequirers(["gen.service"], ["gen.service", "req.service"], host)
    check late.hold == @["late.service"]
    check late.essential == @["sshd.service"]

suite "names, templates, targets, a dead apply's holds and boot starts (A13 review round 12)":
  # The reviewer's round-12 probes (P1-P4) and the owner's four decisions
  # of 2026-11-16 as tests. ``systemdLike`` refuses a template's own name,
  # as systemd 260 does; ``simHost`` starts units as systemd does.
  proc scratch12(tag: string): string =
    result = getTempDir() / ("t-r12-" & tag & "-" & $getCurrentProcessId())
    removeDir(result)
    createDir(result)

  proc systemdLike(shows: Table[string, Table[string, string]];
                   loaded: seq[string] = @[]): LiveHost =
    LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        if u.endsWith("@.service"):
          raise newException(OSError, "Unit name " & u &
            " is neither a valid invocation ID nor unit name.")
        # As systemctl show answers for a unit it cannot find.
        if u notin shows: return {"LoadState": "not-found"}.toTable
        shows[u],
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""),
      list: proc (pattern: string): seq[string] =
        let stem = pattern[0 ..< pattern.find('*')]
        for n in loaded:
          if n.startsWith(stem): result.add(n))

  const Gen12 = """systemd.systemUnit {
  name = "s.socket"
  content = "[Socket]
ListenStream=/run/s
"
}
systemd.systemUnit {
  name = "s.service"
  content = "[Service]
ExecStart=/bin/true
"
}
"""

  proc entry12(p: SystemProfile; t: string; units: seq[string]): TriggerRestartEntry =
    result = TriggerRestartEntry(unit: t)
    for u in @[t] & units:
      result.rendered.add((unit: u, digest: renderedUnitDigest(p, u)))

  test "M1: an alias is matched by systemd's Id, so logind's D-Bus alias is essential":
    # P4: a generation's drop-in on dbus-org.freedesktop.login1.service, an
    # alias of systemd-logind.service, requires the judged unit.
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemDropIn {
  unit = "dbus-org.freedesktop.login1.service"
  name = "a13-ess"
  content = "[Unit]
Requires=gen.service
"
}
""")
    var shows = initTable[string, Table[string, string]]()
    shows["gen.service"] = {"Id": "gen.service"}.toTable
    shows["dbus-org.freedesktop.login1.service"] =
      {"Id": "systemd-logind.service"}.toTable
    shows["systemd-logind.service"] = {"Id": "systemd-logind.service"}.toTable
    let host = systemdLike(shows)
    let r = preWriteRequirers(p, ["gen.service"], host)
    checkpoint "held: " & $r
    check r == @["systemd-logind.service"]
    check essentialInHoldSet(["gen.service"], r, [], host) ==
      @["systemd-logind.service"]

  test "M1: a judged template's requirers are read through its loaded and running instances":
    # P1: a host drop-in makes ssh.service bind to pg@main.service; the
    # template's own name cannot be shown.
    var shows = initTable[string, Table[string, string]]()
    shows["pg@main.service"] = {"BoundBy": "ssh.service"}.toTable
    shows["ssh.service"] = initTable[string, string]()
    let host = systemdLike(shows, loaded = @["pg@main.service"])
    let r = preWriteRequirers(SystemProfile(), ["pg@.service"], host)
    checkpoint "found: " & $r
    check "ssh.service" in r
    check essentialInHoldSet(["pg@.service"], r, [], host) == @["ssh.service"]

  test "M1: an essential judged unit refuses, as an essential requirer does":
    # P2: what would be held is the judged unit itself.
    var shows = initTable[string, Table[string, string]]()
    shows["sshd.service"] = initTable[string, string]()
    let host = systemdLike(shows)
    let r = preWriteRequirers(SystemProfile(), ["sshd.service"], host)
    check r.len == 0
    check essentialInHoldSet(["sshd.service"], r, [], host) == @["sshd.service"]

  test "M1: an essential trigger refuses, as an essential requirer does":
    let host = systemdLike(initTable[string, Table[string, string]]())
    check essentialInHoldSet(["app.service"], [], ["ssh.socket"], host) ==
      @["ssh.socket"]
    check essentialInHoldSet(["app.service"], [], ["app.socket"], host).len == 0

  test "never hold .target units: a judged unit RequiredBy=multi-user.target holds no target":
    # P3, and a unit that requires multi-user.target is still found through
    # it (the owner decision "never hold .target units").
    var shows = initTable[string, Table[string, string]]()
    shows["app.service"] = {"RequiredBy": "multi-user.target"}.toTable
    shows["multi-user.target"] =
      {"RequiredBy": "graphical.target late.service"}.toTable
    shows["graphical.target"] = initTable[string, string]()
    shows["late.service"] = initTable[string, string]()
    let r = preWriteRequirers(SystemProfile(), ["app.service"],
                              systemdLike(shows))
    checkpoint "held: " & $r
    check "multi-user.target" notin r
    check "graphical.target" notin r
    check r == @["late.service"]

  test "M2: a full apply starts what its generation resolves, confirmed, before its commit":
    let dir = scratch12("m2start")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen12)
    writeTriggerRestartEntries(dir, [entry12(restartRecordProfile(g),
                                             "s.socket", @["s.service"])])
    # The socket unchanged, its service changed: the entry is resolved.
    let fixed = parseSystemProfile(Gen12.replace("ExecStart=/bin/true",
                                                 "ExecStart=/bin/false"))
    var log = new seq[string]
    let none = getTempDir() / "t-r12-no-pointer"
    check fullApplyStartResolved(dir, fixed, simHost(log), pointer = none).len == 0
    check "start s.socket" in log[]
    # One whose start a hold skips fails the apply.
    log[].setLen(0)
    let probs = fullApplyStartResolved(dir, fixed,
      simHost(log, skipped = @["s.socket"]), pointer = none)
    check probs.len == 1
    check "s.socket" in probs[0]
    check readTriggersToRestart(dir) == @["s.socket"]

  test "M2: a full apply with an error clears no entry; a clean one clears what it resolves":
    let dir = scratch12("m2clear")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen12)
    writeTriggerRestartEntries(dir, [entry12(restartRecordProfile(g),
                                             "s.socket", @["s.service"])])
    let fixed = parseSystemProfile(Gen12.replace("ExecStart=/bin/true",
                                                 "ExecStart=/bin/false"))
    let none = getTempDir() / "t-r12-no-pointer"
    fullApplyCommitted(dir, fixed, clean = false, pointer = none)
    check readTriggersToRestart(dir) == @["s.socket"]
    fullApplyCommitted(dir, fixed, clean = true, pointer = none)
    check not hasTriggersToRestart(dir)

  test "the fixing path fails closed when systemd cannot be asked about a resolved unit":
    let dir = scratch12("showfail")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen12)
    writeTriggerRestartEntries(dir, [entry12(g, "s.socket", @["s.service"])])
    let fixed = parseSystemProfile(Gen12.replace("ExecStart=/bin/true",
                                                 "ExecStart=/bin/false"))
    var log = new seq[string]
    var host = simHost(log)
    host.show = proc (u: string): Table[string, string] =
      raise newException(OSError, "Failed to connect to bus")
    let probs = startResolvedRestartEntries(dir, fixed, host)
    check probs.len == 1
    check "could not be asked" in probs[0]

  test "M3: the next apply adopts a dead apply's held units and triggers, keeping their holds":
    let state = scratch12("m3adopt")
    let holds = state / "run-systemd-system"
    defer: removeDir(state)
    recordLiveCheckUnits(state, [(unit: "svc.service", wasActive: true)])
    recordLiveCheckTriggers(state, ["svc.socket"])
    let written = writeHolds(["svc.service", "svc.socket", "old.service"],
                             CarriedCheckHoldName, "x", holds)
    let dead = deadApplyHeld(state, holds)
    check (unit: "svc.service", wasActive: true) in dead.units
    check (unit: "old.service", wasActive: false) in dead.units
    check dead.triggers == @["svc.socket"]
    # No hold of the dead apply is lifted before this apply's check.
    for h in written: check fileExists(h)

  test "M3: recover lifts only the triggers' own holds, and leaves a trigger whose unit is held":
    let state = scratch12("m3recover")
    let holds = state / "run-systemd-system"
    defer: removeDir(state)
    let lockPath = state / "host-apply.lock"
    putEnv(HostApplyLockEnvVar, lockPath)
    defer: delEnv(HostApplyLockEnvVar)
    recordLiveCheckTriggers(state, ["a.socket", "b.timer"])
    discard writeHolds(["a.service", "a.socket", "b.timer"],
                       CarriedCheckHoldName, "x", holds)
    var log = new seq[string]
    var host = simHost(log)
    let base = host.show
    host.show = proc (u: string): Table[string, string] =
      result = base(u)
      if u == "a.socket": result["Triggers"] = "a.service"
      if u == "b.timer": result["Triggers"] = "b.service"
    let r = repairTriggerRecords(state, host, holdDir = holds)
    checkpoint $r.lines
    check r.resolved
    # The judged service's hold stays, and so does its socket's, on record.
    check fileExists(holdPath("a.service", CarriedCheckHoldName, holds))
    check fileExists(holdPath("a.socket", CarriedCheckHoldName, holds))
    check readLiveCheckTriggers(state) == @["a.socket"]
    check "start a.socket" notin log[]
    # The timer's own hold is lifted and the timer started.
    check not fileExists(holdPath("b.timer", CarriedCheckHoldName, holds))
    check "start b.timer" in log[]

  test "M4: at boot the records' starts are queued, not waited for, and stay on record":
    let state = scratch12("m4boot")
    defer: removeDir(state)
    let lockPath = state / "host-apply.lock"
    putEnv(HostApplyLockEnvVar, lockPath)
    defer: delEnv(HostApplyLockEnvVar)
    recordLiveCheckTriggers(state, ["lc.socket"])
    writeTriggerRestartEntries(state, [
      TriggerRestartEntry(unit: "r.socket"),
      TriggerRestartEntry(unit: "dep.service", dependantOf: "r.socket")])
    var log = new seq[string]
    var host = simHost(log)
    host.startNoBlock = proc (u: string): tuple[ok: bool, output: string] =
      log[].add("queue " & u)
      (true, "")
    let r = repairTriggerRecords(state, host, atBoot = true)
    checkpoint $log[]
    check r.resolved
    check log[].filterIt(it.startsWith("start ")).len == 0
    check log[].filterIt(it.startsWith("queue ")) ==
      @["queue lc.socket", "queue r.socket", "queue dep.service"]
    check readLiveCheckTriggers(state) == @["lc.socket"]
    check readTriggersToRestart(state) == @["r.socket", "dep.service"]

  test "M4: a boot replay's fixing starts are queued and not confirmed":
    let dir = scratch12("m4fix")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen12)
    writeTriggerRestartEntries(dir, [entry12(g, "s.socket", @["s.service"])])
    let fixed = parseSystemProfile(Gen12.replace("ExecStart=/bin/true",
                                                 "ExecStart=/bin/false"))
    var log = new seq[string]
    # A start that would not come up yet (its dependency is not up at this
    # point of the boot): queued, it is no failure of the replay.
    var host = simHost(log, skipped = @["s.socket"])
    host.startNoBlock = proc (u: string): tuple[ok: bool, output: string] =
      log[].add("queue " & u)
      (true, "")
    check startResolvedRestartEntries(dir, fixed, host, noBlock = true).len == 0
    check log[].filterIt(it.startsWith("start ")).len == 0
    check "queue s.socket" in log[]

  test "decision 180: recover leaves on record, with its hold, a trigger whose unit is still held":
    # The implementer's clarification of decision 180, accepted by the
    # coordinator: started now, a socket with a pending connection would
    # fire at the held service until systemd's trigger limit failed it, so
    # it waits for the next full apply, which starts it after its check.
    let state = scratch12("d180held")
    let holds = state / "run-systemd-system"
    defer: removeDir(state)
    putEnv(HostApplyLockEnvVar, state / "host-apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    recordLiveCheckTriggers(state, ["h.socket"])
    discard writeHolds(["h.service", "h.socket"], CarriedCheckHoldName, "x", holds)
    var log = new seq[string]
    var host = simHost(log)
    let base = host.show
    host.show = proc (u: string): Table[string, string] =
      result = base(u)
      if u == "h.socket": result["Triggers"] = "h.service"
    let r = repairTriggerRecords(state, host, holdDir = holds)
    checkpoint $r.lines
    check r.resolved
    check readLiveCheckTriggers(state) == @["h.socket"]
    check fileExists(holdPath("h.socket", CarriedCheckHoldName, holds))
    check fileExists(holdPath("h.service", CarriedCheckHoldName, holds))
    check log[].filterIt(it.startsWith("start ")).len == 0
    check r.lines.anyIt("left for the next full apply" in it and "h.socket" in it)

  test "M2: a full apply compares the record with the generation as written, not its carried-state requirements":
    # Only the shape differs: the text the apply runs carries the restore
    # requirement's drop-in on the validator (``withCarriedRequirements``);
    # the generation is otherwise unchanged, so the entry stays unresolved.
    # Its own backup: earlier cases change the shared one.
    let src = fresh("r12-shape-src")
    createDir(src / "var/lib/ethereum/validator")
    writeFile(src / "var/lib/ethereum/validator/validator.db", "history\n")
    let d = src / "out"
    discard backupStateSet(parseSystemProfile(Validator), d, "h", stopped(),
                           hold = false, root = src)
    let root = fresh("r12-shape-root")
    discard restoreStateSet(d, stopped(), root = root)
    writeFile(installedMarkerPath(d), d & "\n")
    let applied = withCarriedRequirements(Validator, d, root)
    check applied != Validator
    let written = parseSystemProfile(Validator)
    let e = entry12(restartRecordProfile(written), "eth-validator.service", @[])
    # Since round 13 (M-A, the owner's "yes, exclude them") the digest
    # leaves the requirement's drop-ins out on both sides, so the applied
    # text renders the unit as the written one does, and neither resolves
    # the entry.
    check renderedUnitDigest(restartRecordProfile(parseSystemProfile(applied)),
                             "eth-validator.service") == e.rendered[0].digest
    check not restartEntryResolvedBy(e,
      fullApplyRecordProfile(recordComparisonProfile(Validator, applied)))
    check not restartEntryResolvedBy(e,
      fullApplyRecordProfile(parseSystemProfile(applied)))

  # --- A13 review round 13 (the reviewer's probes P1-P4 as cases) -------
  const W13 = "systemd.systemUnit {\n  name = \"eth-validator.service\"\n" &
    "  content = \"[Service]\nExecStart=/bin/true\n\"\n}\n"
  const Req13 = "\nsystemd.systemDropIn {\n  unit = \"eth-validator.service\"\n" &
    "  name = \"state-restore\"\n  content = \"[Unit]\nRequires=repro-state-restore.service\n" &
    "After=repro-state-restore.service\n\"\n}\n"

  test "M-A: a rollback's stored text with the requirement does not resolve an entry recorded without it":
    # P1: the full apply stores (and a rollback re-applies) the text the
    # carried-state requirement extends.
    let e = entry12(restartRecordProfile(parseSystemProfile(W13)),
                    "eth-validator.service", @[])
    let stored = W13 & Req13
    check not restartEntryResolvedBy(e,
      fullApplyRecordProfile(recordComparisonProfile(stored, stored)))

  test "M-A: an add-on record with the requirement is not resolved by the written text without it":
    # P2: the add-on recorded while carried state was installed.
    let e = entry12(restartRecordProfile(parseSystemProfile(W13 & Req13)),
                    "eth-validator.service", @[])
    check not restartEntryResolvedBy(e,
      fullApplyRecordProfile(recordComparisonProfile(W13, W13 & Req13)))
    # A real change still resolves it.
    check restartEntryResolvedBy(e, fullApplyRecordProfile(parseSystemProfile(
      W13.replace("ExecStart=/bin/true", "ExecStart=/bin/false"))))

  test "M-D: recover leaves an Accept=yes socket whose template service is still held":
    # P3: systemd shows no Triggers= for an Accept=yes socket.
    let state = scratch12("m13p3")
    defer: removeDir(state)
    let holds = state / "run"
    putEnv(HostApplyLockEnvVar, state / "lock")
    defer: delEnv(HostApplyLockEnvVar)
    recordLiveCheckTriggers(state, ["e.socket"])
    discard writeHolds(["e@.service", "e.socket"], CarriedCheckHoldName, "x", holds)
    var log = new seq[string]
    let active = new seq[string]
    let host = LiveHost(
      isActive: proc (u: string): bool = u in active[],
      show: proc (u: string): Table[string, string] =
        result = {"LoadState": "loaded", "Accept": "yes", "Triggers": ""}.toTable
        result["ActiveState"] = (if u in active[]: "active" else: "inactive"),
      start: proc (u: string): tuple[ok: bool, output: string] =
        log[].add("start " & u); active[].add(u); (true, ""),
      stop: proc (u: string): tuple[ok: bool, output: string] = (true, ""),
      resetFailed: proc (u: string) = discard)
    discard repairTriggerRecords(state, host, holdDir = holds)
    check "start e.socket" notin log[]
    check readLiveCheckTriggers(state) == @["e.socket"]

  test "M-C: a profile drop-in re-pointing a host socket, and Sockets=, make triggers of the judged unit":
    # P4: ssh.socket re-pointed at gen.service, sshd.socket named by it.
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemDropIn {
  unit = "ssh.socket"
  name = "a13-repoint"
  content = "[Socket]
Service=gen.service
"
}
systemd.systemDropIn {
  unit = "gen.service"
  name = "a13-sockets"
  content = "[Service]
Sockets=sshd.socket
"
}
""")
    let pt = profileTriggersOf(p, ["gen.service"])
    checkpoint "profileTriggersOf: " & $pt
    check "ssh.socket" in pt
    check "sshd.socket" in pt
    # So the apply is refused before it writes anything (decision 177(c)).
    let host = systemdLike(initTable[string, Table[string, string]]())
    check essentialInHoldSet(["gen.service"], [], pt, host) ==
      @["ssh.socket", "sshd.socket"]

  test "M-C: an essential trigger systemd names only after the reload is reported, never stopped or held":
    let host = systemdLike(initTable[string, Table[string, string]]())
    let late = postReloadTriggers(["ssh.socket", "app.socket", "old.socket"],
                                  ["old.socket"], host)
    check late.essential == @["ssh.socket"]
    check late.stop == @["app.socket"]

  test "M-F: the triggers of a held requirer are held too":
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "req.service"
  content = "[Unit]
Requires=gen.service
[Service]
ExecStart=/bin/true
"
}
systemd.systemUnit {
  name = "req.timer"
  content = "[Timer]
OnCalendar=daily
"
}
""")
    let reqs = profileRequirersOf(p, ["gen.service"])
    check reqs == @["req.service"]
    check "req.timer" in profileTriggersOf(p, triggerUnitsOfHold(["gen.service"], reqs))

  test "M-B: a dead apply's judged unit keeps its \"ran before\", and a template's instances are recorded":
    let a = adoptDeadUnits([(unit: "judged.service", wasActive: true),
                            (unit: "other.service", wasActive: false),
                            (unit: "tpl@x.service", wasActive: true)],
                           ["judged.service", "tpl@.service"])
    check a.adopted == @["other.service"]
    check "judged.service" in a.active
    check "tpl@x.service" in a.active
    let rec = liveCheckUnitsRecord(["tpl@.service", "plain.service"],
                                   ["tpl@x.service", "plain.service"])
    check (unit: "tpl@x.service", wasActive: true) in rec
    check (unit: "plain.service", wasActive: true) in rec
    check (unit: "tpl@.service", wasActive: false) in rec

  test "M-E: a trigger systemd cannot be asked about is a problem, and stays on the record":
    let dir = scratch12("m13me")
    defer: removeDir(dir)
    putEnv(HostApplyLockEnvVar, dir / "lock")
    defer: delEnv(HostApplyLockEnvVar)
    writeTriggersToRestart(dir, ["u.socket"])
    var log = new seq[string]
    var host = simHost(log)
    host.show = proc (u: string): Table[string, string] =
      raise newException(OSError, "Failed to connect to bus")
    check triggerRestarts(["u.socket"], [], host).len == 1
    let r = retryTriggerRestarts(dir, host)
    check not r.ok
    check readTriggersToRestart(dir) == @["u.socket"]

  test "L1: a masked trigger is not counted as removed":
    var log = new seq[string]
    var host = simHost(log)
    let base = host.show
    host.show = proc (u: string): Table[string, string] =
      result = base(u)
      result["LoadState"] = (if u == "m.socket": "masked" else: "not-found")
    let probs = triggerRestarts(["m.socket", "gone.socket"], [], host)
    check probs.len == 1 and "m.socket" in probs[0]
    check log[].filterIt(it.startsWith("start ")).len == 0

  test "L1: the fixing path fails on a masked resolved trigger":
    let dir = scratch12("m13l1")
    defer: removeDir(dir)
    let g = parseSystemProfile(Gen12)
    writeTriggerRestartEntries(dir, [entry12(g, "s.socket", @["s.service"])])
    let fixed = parseSystemProfile(Gen12.replace("ExecStart=/bin/true",
                                                 "ExecStart=/bin/false"))
    var log = new seq[string]
    var host = simHost(log)
    let base = host.show
    host.show = proc (u: string): Table[string, string] =
      result = base(u)
      if u == "s.socket": result["LoadState"] = "masked"
    let probs = startResolvedRestartEntries(dir, fixed, host)
    check probs.len == 1 and "LoadState=masked" in probs[0]

  test "L2: a requirer systemd cannot be asked about fails the requirer reading closed":
    # gen.service is readable; the unit that requires it is not.
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        if u == "gen.service": return {"RequiredBy": "x.service"}.toTable
        raise newException(OSError, "Failed to connect to bus"),
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    expect ECarriedStatePending:
      discard systemdRequirersOf(["gen.service"], host)

  test "L2: a name systemd cannot be asked about fails closed":
    let host = LiveHost(
      isActive: proc (u: string): bool = false,
      show: proc (u: string): Table[string, string] =
        raise newException(OSError, "Failed to connect to bus"),
      start: proc (u: string): tuple[ok: bool, output: string] = (true, ""))
    expect ECarriedStatePending:
      discard unitId(host, "dbus-org.freedesktop.login1.service")

  test "decision 177(a): an alias of an essential template is resolved through its instance":
    var shows = initTable[string, Table[string, string]]()
    shows["mygetty@repro-addon-observe.service"] =
      {"Id": "getty@repro-addon-observe.service"}.toTable
    let host = systemdLike(shows)
    check unitId(host, "mygetty@.service") == "getty@.service"
    check essentialInHoldSet(["mygetty@.service"], [], [], host) == @["getty@.service"]

  # --- A13 review round 14 (the reviewer's probes N1-N4 as cases) -------
  test "N1: a drop-in on a dashed prefix, a template or a whole type that sets Service=, Unit= or Sockets= is refused":
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemDropIn {
  unit = "systemd-.socket"
  name = "a13-prefix"
  content = "[Socket]
Service=gen.service
"
}
systemd.systemDropIn {
  unit = "bk@.timer"
  name = "a13-tpl"
  content = "[Timer]
Unit=gen.service
"
}
systemd.systemDropIn {
  unit = "app@.service"
  name = "a13-sockets"
  content = "[Service]
Sockets=sshd.socket
"
}
systemd.systemDropIn {
  unit = "x-.socket"
  name = "a13-harmless"
  content = "[Socket]
Backlog=16
"
}
""")
    let r = triggerDropInRefusal(p)
    checkpoint $r
    check r.len == 3
    check "systemd-.socket sets Service=" in r[0]
    check "bk@.timer sets Unit=" in r[1]
    check "app@.service sets Sockets=" in r[2]

  test "N2: a drop-in on ssh.socket whose Service= names an alias of the judged unit is its trigger":
    let p = parseSystemProfile("""systemd.systemUnit {
  name = "gen.service"
  content = "[Service]
ExecStart=/bin/true
"
}
systemd.systemDropIn {
  unit = "ssh.socket"
  name = "a13-repoint"
  content = "[Socket]
Service=genalias.service
"
}
""")
    var shows = initTable[string, Table[string, string]]()
    shows["genalias.service"] = {"Id": "gen.service"}.toTable
    shows["gen.service"] = {"Id": "gen.service"}.toTable
    let host = systemdLike(shows)
    let pt = profileTriggersOf(p, ["gen.service"], host)
    checkpoint $pt
    check "ssh.socket" in pt
    check essentialInHoldSet(["gen.service"], [], pt, host) == @["ssh.socket"]

  test "N3: recover leaves an instance timer whose template service is held":
    let state = scratch12("n3")
    defer: removeDir(state)
    let holds = state / "run"
    putEnv(HostApplyLockEnvVar, state / "lock")
    defer: delEnv(HostApplyLockEnvVar)
    recordLiveCheckTriggers(state, ["bk@daily.timer"])
    discard writeHolds(["bk@.service", "bk@daily.timer"], CarriedCheckHoldName, "x", holds)
    var log = new seq[string]
    let active = new seq[string]
    let host = LiveHost(
      isActive: proc (u: string): bool = u in active[],
      show: proc (u: string): Table[string, string] =
        result = {"LoadState": "loaded", "Triggers": "bk@daily.service"}.toTable
        result["ActiveState"] = (if u in active[]: "active" else: "inactive"),
      start: proc (u: string): tuple[ok: bool, output: string] =
        log[].add("start " & u); active[].add(u); (true, ""),
      stop: proc (u: string): tuple[ok: bool, output: string] = (true, ""),
      resetFailed: proc (u: string) = discard)
    discard repairTriggerRecords(state, host, holdDir = holds)
    check "start bk@daily.timer" notin log[]
    check readLiveCheckTriggers(state) == @["bk@daily.timer"]

  test "N4: a judged template's running instances are recorded, and adoption keeps them active":
    let rec = liveCheckUnitsRecord(["tpl@.service", "a.service"],
                                   ["tpl@x.service", "a.service", "tplx@y.service"])
    check (unit: "tpl@x.service", wasActive: true) in rec
    check (unit: "tplx@y.service", wasActive: true) notin rec
    let ad = adoptDeadUnits(rec, ["tpl@.service"])
    check "tpl@x.service" in ad.active
    check "a.service" in ad.active and "a.service" in ad.adopted

  test "decision 177(c), 2026-11-18: a late essential trigger fails the apply, naming it and the held unit":
    var shows = initTable[string, Table[string, string]]()
    shows["sshd.socket"] = {"Id": "sshd.socket", "Triggers": "gen.service"}.toTable
    shows["app.socket"] = {"Id": "app.socket", "Triggers": "gen.service"}.toTable
    let host = systemdLike(shows)
    let late = postReloadTriggers(["sshd.socket", "app.socket"], [], host)
    let failures = lateEssentialFailures(late.essential, ["gen.service"], host)
    checkpoint $failures
    check failures.len == 1
    check "sshd.socket is essential and triggers gen.service" in failures[0]
    check "app.socket" notin failures[0]

  test "an Accept=yes socket, an instance's included, triggers its prefix's template":
    let accept = {"Accept": "yes"}.toTable
    check acceptTemplateOf("foo@x.socket", accept) == "foo@.service"
    check acceptTemplateOf("foo.socket", accept) == "foo@.service"
    check acceptTemplateOf("foo.socket", {"Accept": "no"}.toTable) == ""

  # --- A13 review round 15 (the reviewer's probes P1-P10 as cases) ------
  proc di15(unit, body: string): string =
    "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"p\"\n  content = \"" & body & "\"\n}\n"
  const Gen15 = "systemd.systemUnit {\n  name = \"gen.service\"\n  content = \"[Service]\nExecStart=/bin/true\n\"\n}\n"
  proc refusal15(unit, body: string): seq[string] =
    triggerDropInRefusal(parseSystemProfile(Gen15 & di15(unit, body)))

  test "round 15: prefix and template drop-ins that re-point triggers are refused, -.socket, timers and paths included":
    check refusal15("-.socket", "[Socket]\nService=gen.service\n").len == 1
    check refusal15("systemd-.service", "[Service]\nSockets=sshd.socket\n").len == 1
    check refusal15("bk-.timer", "[Timer]\nUnit=gen.service\n").len == 1
    check refusal15("pp-.path", "[Path]\nUnit=gen.service\n").len == 1
    check refusal15("pp@.path", "[Path]\nUnit=gen.service\n").len == 1
    check refusal15("systemd-.socket", "[Socket]\nService = gen.service\n").len == 1

  test "round 15: resource limits, comments and a named unit's drop-in are not refused here":
    check refusal15("systemd-.service", "[Service]\nMemoryMax=1G\nCPUQuota=50%\n").len == 0
    check refusal15("app@.service", "[Service]\nLimitNOFILE=4096\n").len == 0
    check refusal15("x-.socket", "[Socket]\nBacklog=16\n# Service=gen.service\n").len == 0
    check refusal15("ssh.socket", "[Socket]\nService=gen.service\n").len == 0

  test "round 15: a type-wide drop-in is refused by the unit-name validation, never reaching the refusal":
    check systemdUnitNameError("u", "socket").len > 0
    check systemdUnitNameError("u", "-.socket").len == 0

  test "P9: a dashed prefix that keeps an instance (app-@x.socket) setting Service= is refused":
    check dropInApplies("app-@x.socket", "app-a@x.socket")
    let r = refusal15("app-@x.socket", "[Socket]\nService=gen.service\n")
    checkpoint $r
    check r.len == 1 and "app-@x.socket sets Service=" in r[0]

  test "P10: the same for Sockets= on gen-@x.service":
    let r = refusal15("gen-@x.service", "[Service]\nSockets=sshd.socket\n")
    checkpoint $r
    check r.len == 1 and "gen-@x.service sets Sockets=" in r[0]

# --- A13 review round 15: the owner's decisions of 2026-11-25 ------------
suite "the restore beside other units (§13 decision 191)":
  test "decision 191: the restore unit is not before sysinit.target, and is bounded":
    # Falsifiers: restore-holds-sysinit (the ordering back) and
    # restore-unbounded (no start timeout).
    let t = stateRestoreUnitText("/usr/bin/repro", @["eth-validator.service"])
    checkpoint t
    var before = ""
    for l in t.splitLines():
      if l.startsWith("Before="): before = l
    check before == "Before=shutdown.target eth-validator.service"
    check "sysinit.target" notin before
    check ("TimeoutStartSec=" & RestoreStartTimeout & "\n") in t
    check RestoreStartTimeout == "90min"
    # Still pulled in at sysinit, and still never conditioned.
    check "WantedBy=sysinit.target" in t
    check "DefaultDependencies=no" in t

  test "decision 191: a placeholder written to during the restore is refused, not removed":
    # Falsifier: restore-removes-filled-placeholder (the round-14 recursive
    # removal), under which the concurrent unit's file is lost.
    let base = fresh("r15-place")
    let staging = base / ".repro-restore-v-1"
    let target = base / "v"
    createDir(staging)
    writeFile(staging / "validator.db", "history\n")
    createDir(target)
    writeFile(target / "written-meanwhile", "a concurrent unit's\n")
    expect StateSetError:
      placeStagedTree(staging, target, "/var/lib/v")
    check readFile(target / "written-meanwhile") == "a concurrent unit's\n"
    check fileExists(staging / "validator.db")
    # Control: an empty placeholder, and none at all, take the tree.
    removeFile(target / "written-meanwhile")
    placeStagedTree(staging, target, "/var/lib/v")
    check readFile(target / "validator.db") == "history\n"
    check not dirExists(staging)
    let staging2 = base / ".repro-restore-w-1"
    createDir(staging2)
    writeFile(staging2 / "x", "y\n")
    placeStagedTree(staging2, base / "w", "/var/lib/w")
    check readFile(base / "w" / "x") == "y\n"

proc installed15(name: string): (string, string) =
  ## As ``installedR6``, from a backup of its own (the shared one may have
  ## been consumed by the suites before).
  let src = fresh(name & "-src")
  createDir(src / "var/lib/ethereum/validator")
  writeFile(src / "var/lib/ethereum/validator/validator.db", "history\n")
  let d = src / "carried"
  discard backupStateSet(parseSystemProfile(Validator), d, "h", stopped(),
                         hold = false, root = src)
  let root = fresh(name)
  discard restoreStateSet(d, stopped(), root = root)
  writeFile(installedMarkerPath(d), d & "\n")
  (root, d)

suite "an essential unit never requires the restore (§13 decision 192)":
  # Each unit is resolved by its Id= (decision 177): a stub systemd that
  # knows an alias of logind and an instance of a getty template.
  proc ids(aliases: Table[string, string]): LiveHost =
    LiveHost(show: proc (u: string): Table[string, string] =
      if u in aliases: {"Id": aliases[u]}.toTable
      else: {"Id": u}.toTable)
  let none = ids(initTable[string, string]())
  proc refusals192(text: string; root, d: string; host: LiveHost): seq[string] =
    result = essentialRequirementRefusal(parseSystemProfile(text), d, root, host)
    checkpoint $result

  test "decision 192, route 1: a profile drop-in over sshd.service":
    let (root, d) = installed15("r15-ess1")
    let r = refusals192("systemd.systemDropIn {\n  unit = \"sshd.service\"\n" &
      "  name = \"harden\"\n  content = \"[Service]\nEnvironment=A=1\n\"\n}\n",
      root, d, none)
    check r.len == 1
    check "sshd.service is essential and would require the carried-state " &
      "restore: a profile drop-in over it (harden)" in r[0]

  test "decision 192, route 2: a profile that defines an essential unit reaching everything":
    let (root, d) = installed15("r15-ess2")
    let r = refusals192(unit("dbus.service",
      "[Service]\nExecStart=/bin/true\n"), root, d, none)
    check r.len == 1 and "dbus.service is essential" in r[0] and
      "the profile defines it" in r[0]

  test "decision 192, route 3: a unit a profile unit starts, the boot's included":
    let (root, d) = installed15("r15-ess3")
    hostFile(root, "/lib/systemd/system/default.target",
      "[Unit]\nWants=systemd-networkd.service\n")
    hostFile(root, "/lib/systemd/system/systemd-networkd.service",
      "[Service]\nExecStart=/bin/true\n")
    let starter = unit("st.service", "[Unit]\nWants=systemd-networkd.service\n" &
      "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    let r = refusals192(starter, root, d, none)
    # A directly started unit gets the requirement whatever the boot says
    # (route 3, as §11.1 now reads), so it is refused though the boot
    # starts it too.
    check r.len == 1 and "systemd-networkd.service is essential" in r[0] and
      "the profile's st.service starts it" in r[0]

  test "decision 192, route 4: decision 60's onward dependency closure":
    let (root, d) = installed15("r15-ess4")
    hostFile(root, "/lib/systemd/system/default.target", "[Unit]\n")
    hostFile(root, "/lib/systemd/system/online.target",
      "[Unit]\nWants=systemd-networkd-wait-online.service\n")
    hostFile(root, "/lib/systemd/system/systemd-networkd-wait-online.service",
      "[Service]\nExecStart=/bin/true\n")
    let starter = unit("on.service", "[Unit]\nWants=online.target\n" &
      "[Service]\nProtectSystem=strict\nNoNewPrivileges=yes\nUser=app\n" &
      "ReadWritePaths=/var/lib/other\nExecStart=/bin/true\n")
    let r = refusals192(starter, root, d, none)
    check r.len == 1 and "systemd-networkd-wait-online.service is essential" in r[0] and
      "decision 60's onward dependency closure" in r[0]

  test "decision 192: an alias and a template instance are matched by Id=":
    let (root, d) = installed15("r15-ess5")
    let host = ids({"dbus-org.freedesktop.login1.service":
                    "systemd-logind.service"}.toTable)
    let r = refusals192("systemd.systemDropIn {\n  unit = " &
      "\"dbus-org.freedesktop.login1.service\"\n  name = \"x\"\n  content = " &
      "\"[Service]\nEnvironment=A=1\n\"\n}\n" &
      "systemd.systemDropIn {\n  unit = \"getty@tty3.service\"\n  name = \"y\"\n" &
      "  content = \"[Service]\nEnvironment=A=1\n\"\n}\n", root, d, host)
    check r.len == 2
    check "dbus-org.freedesktop.login1.service (systemd-logind.service) is essential" in r[0] or
      "dbus-org.freedesktop.login1.service (systemd-logind.service) is essential" in r[1]
    check "getty@tty3.service is essential" in r[0] or
      "getty@tty3.service is essential" in r[1]

  test "decision 192 (control): no carried state installed, or no essential unit, refuses nothing":
    let (root, d) = installed15("r15-ess6")
    check refusals192(unit("ok.service", "[Service]\nExecStart=/bin/true\n"),
      root, d, none).len == 0
    removeFile(installedMarkerPath(d))
    check refusals192("systemd.systemDropIn {\n  unit = \"sshd.service\"\n" &
      "  name = \"harden\"\n  content = \"[Service]\nEnvironment=A=1\n\"\n}\n",
      root, d, none).len == 0

suite "a secret put is a switch for the carried-state check (§13 decision 190)":
  test "decision 190: a put judges the consumers it restarts, and refuses one loaded as root":
    # Falsifier: secret-put-unjudged (nothing is judged).
    let judged = secretPutJudged(["a.service", "tpl@1.service", "other.service"],
                                 ["a.service", "tpl@.service"])
    check judged == @["a.service", "tpl@1.service"]
    var reloads = 0
    let p = parseSystemProfile(unit("a.service",
      "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\nExecStart=/bin/true\n"))
    let rootShow = proc (u: string): Table[string, string] =
      {"ProtectSystem": "strict", "DynamicUser": "no", "NoNewPrivileges": "yes",
       "User": "root", "Group": "root", "SupplementaryGroups": ""}.toTable
    let problems = secretPutLiveProblems(["a.service"], p, rootShow,
      proc () = inc reloads)
    checkpoint $problems
    check reloads == 1
    check problems.len == 1 and "a.service as systemd loaded it is not confined" in problems[0]
    # Control: nothing to judge, nothing reloaded.
    check secretPutLiveProblems([], p, rootShow, proc () = inc reloads).len == 0
    check reloads == 1

  test "decision 190: a put judges its consumers in the composed profile, own and user":
    # Falsifier: secret-put-user-profile-only. A credential consumer
    # starts repro-addon-secrets.service, which only the add-on's own
    # profile defines: in the user profile alone it reaches everything and
    # is never judged (the first measurement at a491dae2cc).
    let (root, d) = installed15("r15-put-compose")
    let user = "secrets.secretFile {\n  service = \"a13p\"\n  name = \"token\"\n}\n" &
      unit("a13p.service", "[Service]\nDynamicUser=yes\nNoNewPrivileges=yes\n" &
        "ExecStart=/bin/sleep infinity\n", "  credentials = [\"token\"]\n" &
        "  floorExceptions = [\"serviceFloor: the decision-190 probe\"]\n")
    let own = unit("repro-addon-secrets.service",
      "[Service]\nType=oneshot\nExecStart=/bin/true\n")
    let composed = composedLiveProfile(own, user)
    checkpoint $liveReachUnits(composed, d, root)
    check "a13p.service" in liveReachUnits(composed, d, root)
    # Control: the user profile alone leaves the consumer unjudged.
    check "a13p.service" notin liveReachUnits(composedLiveProfile("", user), d, root)

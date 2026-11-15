## The boot-hold unit and generation 0's upgrade path (ReproOS Add-On Mode
## spec §6.2, §10.1, §13 decision 159; A9 review round 15):
##
## - generation 0 carries ``repro-addon-boot-hold.service``, ordered before
##   ``sysinit.target`` and so before every socket, path and timer unit,
##   conditioned on the pending marker;
## - every switch adds the generation-0 objects its own profile lacks
##   (``addMissingGeneration0``): it only adds, refuses a path that is there
##   and is not the add-on's object, checks every candidate before adding
##   any, and is idempotent;
## - a switch records its start holds; the unit's shell copies them back at
##   boot while the switch is pending, and ``releaseBootHolds`` lifts exactly
##   those once it is resolved.
##
## Falsifying builds, red here: ``boot-hold-after-sysinit`` (the unit's
## order) and ``gen0-not-upgraded`` (no upgrade). ``boot-holds-unrecorded``
## acts at the switch's call site and is red in the VM gate
## ``t_e2e_addon_floor_reapplies_after_restarts``.
##
## *Mocking.* The upgrade's file-system probe and the committed ledger's
## digests are closures, so a path present with foreign bytes and a failure
## part-way through can be stated exactly; the VM gate drives the same code
## against a host an earlier engine bootstrapped. The unit's own script runs
## under ``/bin/sh`` with its paths moved under a temporary root and a
## ``systemctl`` stand-in on ``PATH`` that logs the reload: the gate
## measures the reload's effect at a real boot.

import std/[os, strutils, tempfiles, unittest]

import repro_addon/boot_holds
import repro_addon/effective_floor
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/static_tree
import repro_infra/start_holds

const Exe = "/repro/store/prefixes/repro-addon-bin/x/bin/repro"

proc gen0(): seq[OwnObject] =
  generation0Objects(Gen0Inputs(reproExe: Exe))

proc withoutBootHold(objs: seq[OwnObject]): seq[OwnObject] =
  for o in objs:
    if o.kind != ookUnit or o.unit != BootHoldUnit: result.add(o)

let current = renderOwnProfile(gen0(), "/f")
let previousEngine = renderOwnProfile(withoutBootHold(gen0()), "/f")

proc absent(p: string): tuple[present: bool; sha256: string] = (false, "")
proc unrecorded(p: string): string = ""

suite "§13 decision 159: the boot-hold unit":
  let u = bootHoldUnit()
  test "generation 0 carries it, enabled, beside the re-assert unit":
    var found = false
    for o in gen0():
      if o.kind == ookUnit and o.unit == BootHoldUnit:
        found = true
        check o.enabled
        check o.path == "/etc/systemd/system/" & BootHoldUnit
    check found
  test "it runs before sysinit.target, without default dependencies":
    check "DefaultDependencies=no\n" in u
    check "Before=sysinit.target shutdown.target\n" in u
    check "After=sysinit.target" notin u
    check "WantedBy=sysinit.target\n" in u
  test "only while a switch is pending, and never on the store mount":
    check "ConditionPathExists=" & PendingMarkerPath & "\n" in u
    check PendingMarkerPath == pendingMarkerPath(SystemStateDir)
    check "Requires=" notin u
    # The base's shell, never the store binary, which may predate it.
    let exec = u.split("ExecStart=")[1].split("\n")[0]
    check exec.startsWith("/bin/sh -c '") and "/repro/store" notin exec and
      "system addon" notin exec

suite "§13 decision 159: generation 0's upgrade path":
  test "an own profile without the unit gets it, rendered as a bootstrap would":
    let miss = missingGeneration0Objects(previousEngine)
    check miss.len == 1
    check miss[0].unit == BootHoldUnit
    check miss[0].content == bootHoldUnit()
    let up = addMissingGeneration0(previousEngine, miss, absent, unrecorded)
    check up == current
  test "it only adds: every other block is unchanged":
    let up = addMissingGeneration0(previousEngine,
      missingGeneration0Objects(previousEngine), absent, unrecorded)
    for o in withoutBootHold(gen0()):
      if o.kind == ookUnit:
        check unitContentOf(up, o.unit) == unitContentOf(previousEngine, o.unit)
  test "idempotent: an own profile carrying it has nothing missing":
    check missingGeneration0Objects(current).len == 0
    check addMissingGeneration0(current, missingGeneration0Objects(current),
                                absent, unrecorded) == current
  test "present and matching: the ledger records exactly those bytes":
    let miss = missingGeneration0Objects(previousEngine)
    let sha = sha256Hex(miss[0].content)
    let up = addMissingGeneration0(previousEngine, miss,
      proc (p: string): tuple[present: bool; sha256: string] = (true, sha),
      proc (p: string): string = sha)
    check up == current
  test "present and foreign: refused, never written over":
    let miss = missingGeneration0Objects(previousEngine)
    let sha = sha256Hex(miss[0].content)
    for (probe, rec) in [
        ((true, sha256Hex("operator's\n")), ""),           # not the add-on's
        ((true, sha), ""),                                 # unrecorded bytes
        ((true, sha256Hex("operator's\n")), sha),          # changed since
        ((true, ""), "")]:                                 # a link, a directory
      let pr = probe
      let rc = rec
      expect ValueError:
        discard addMissingGeneration0(previousEngine, miss,
          proc (p: string): tuple[present: bool; sha256: string] = pr,
          proc (p: string): string = rc)
  test "a failure part-way adds nothing":
    # The first candidate's path is free, the second's is foreign: the
    # check runs over all of them before any is added.
    let miss = missingGeneration0Objects(previousEngine) & @[OwnObject(
      kind: ookUnit, unit: "repro-addon-later.service",
      path: "/etc/systemd/system/repro-addon-later.service",
      content: "[Unit]\nDescription=x\n", enabled: false)]
    var probed: seq[string]
    var raised = false
    try:
      discard addMissingGeneration0(previousEngine, miss,
        proc (p: string): tuple[present: bool; sha256: string] =
          probed.add(p)
          if p.endsWith("later.service"): (true, sha256Hex("foreign")) else: (false, ""),
        unrecorded)
    except ValueError as e:
      raised = true
      check "repro-addon-later.service" in e.msg
    check raised
    check probed.len == 2

suite "§13 decision 159: the start holds across a reboot":
  type Sandbox = tuple[state, root, written, bin, log: string]
  proc setup(): Sandbox =
    let tmp = createTempDir("addon-boot-holds-", "")
    result = (tmp / "state", tmp / "run-systemd-system",
              tmp / "run-addon" / "boot-holds-written", tmp / "bin",
              tmp / "systemctl.log")
    createDir(result.bin)
    # systemctl as the shell finds it on PATH: logs its arguments;
    # ``is-active`` answers from A9_SYSINIT (0: reached).
    writeFile(result.bin / "systemctl", "#!/bin/sh\necho \"$@\" >> " &
      result.log & "\ncase \"$1\" in is-active) exit ${A9_SYSINIT:-3};; esac\nexit 0\n")
    setFilePermissions(result.bin / "systemctl",
      {fpUserRead, fpUserWrite, fpUserExec})
  proc runScript(s: Sandbox; sysinitReached = false): int =
    ## The unit's own script, its paths moved under the sandbox.
    let script = bootHoldScript()
      .replace(BootHoldRecordPath, bootHoldRecordPath(s.state))
      .replace(BootHoldTextPath, bootHoldTextPath(s.state))
      .replace(BootHoldsWrittenList, s.written)
      .replace("/run/repro-addon", parentDir(s.written))
      .replace(RuntimeUnitDirPath, s.root)
    let f = parentDir(s.root) / "script.sh"
    writeFile(f, script)
    # The stand-in first, then the test's own tools (mkdir, cp).
    execShellCmd("env PATH=" & s.bin & ":" & getEnv("PATH") & " A9_SYSINIT=" &
      (if sysinitReached: "0" else: "3") & " sh " & f & " > /dev/null")
  test "the unit carries the script, each $ doubled for systemd":
    # One single-quoted argument: a quote inside it would end the quoting.
    check '\'' notin bootHoldScript()
    check ("ExecStart=/bin/sh -c '" & bootHoldScript().replace("$", "$$") & "'\n") in
      bootHoldUnit()
    check StartHoldFileName == StartHoldName
    check RuntimeUnitDirPath == RuntimeUnitDir
    check BootHoldRecordPath == bootHoldRecordPath(SystemStateDir)
    check BootHoldTextPath == bootHoldTextPath(SystemStateDir)
  test "the switch's record names each hold's drop-in directory once":
    let s = setup()
    writeBootHoldRecord(s.state, [
      "/run/systemd/system/a.service.d/" & StartHoldName,
      "/run/systemd/system/a.socket.d/" & StartHoldName,
      "/run/systemd/system/a.service.d/" & StartHoldName])
    check readBootHoldRecord(s.state) == @["a.service.d", "a.socket.d"]
    check readFile(bootHoldTextPath(s.state)) == StartHoldText
    writeBootHoldRecord(s.state, [])
    check not fileExists(bootHoldRecordPath(s.state))
  test "at boot, the recorded holds are back before the one reload":
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.service.d/" & StartHoldName,
                                  "/run/systemd/system/a.socket.d/" & StartHoldName])
    # Lines the switch never writes steer nothing outside the root.
    writeFile(bootHoldRecordPath(s.state), readFile(bootHoldRecordPath(s.state)) &
      "../escape.d\n.hidden.d\nx/y.d\nnot-a-dir\n")
    check runScript(s) == 0
    check readFile(s.root / "a.service.d" / StartHoldName) == StartHoldText
    check readFile(s.root / "a.socket.d" / StartHoldName) == StartHoldText
    check not fileExists(parentDir(s.root) / "escape.d" / StartHoldName)
    check not dirExists(s.root / ".hidden.d")
    check not dirExists(s.root / "not-a-dir")
    check readFile(s.written).splitLines().len == 3   # two paths and the end
    check readFile(s.log).count("daemon-reload") == 1
  test "nothing once sysinit.target is reached, nothing without a record":
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.service.d/" & StartHoldName])
    check runScript(s, sysinitReached = true) == 0
    check not dirExists(s.root)
    clearBootHoldRecord(s.state)
    check runScript(s) == 0
    check not dirExists(s.root)
    check "daemon-reload" notin readFile(s.log)
  test "the re-assertion lifts the boot's holds only once the switch is resolved":
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.service.d/" & StartHoldName,
                                  "/run/systemd/system/b.service.d/" & StartHoldName])
    writePendingMarker(s.state, PendingMarker(fromGeneration: "g0", step: ssRealise))
    check runScript(s) == 0
    var reloads = 0
    check releaseBootHolds(s.state, proc () = inc(reloads), s.written).len == 0
    check fileExists(s.root / "a.service.d" / StartHoldName)
    # Resolved. A hold whose bytes are no longer the start hold's is not
    # the boot's to lift.
    writeFile(s.root / "b.service.d" / StartHoldName, "operator\n")
    clearPendingMarker(s.state)
    check not fileExists(bootHoldRecordPath(s.state))
    check releaseBootHolds(s.state, proc () = inc(reloads), s.written).len == 1
    check reloads == 1
    check not fileExists(s.root / "a.service.d" / StartHoldName)
    check readFile(s.root / "b.service.d" / StartHoldName) == "operator\n"
    check not fileExists(s.written)

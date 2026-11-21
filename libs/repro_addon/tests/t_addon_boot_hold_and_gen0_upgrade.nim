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
## order), ``gen0-not-upgraded`` (no upgrade) and ``reassert-not-repointed``
## (§13 decision 164: the re-assert unit keeps the bootstrap engine). ``boot-holds-unrecorded``
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
  ## Generation 0 as an engine before decisions 157 and 159 rendered it.
  for o in objs:
    if o.kind != ookUnit or o.unit notin [BootHoldUnit, BootConfirmUnit]: result.add(o)

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
    # Required, so a cycle never deletes its job (§13 decision 172).
    check "RequiredBy=sysinit.target\n" in u
  test "only while a switch is pending, and never on the store mount":
    check "ConditionPathExists=" & PendingMarkerPath & "\n" in u
    check PendingMarkerPath == pendingMarkerPath(SystemStateDir)
    check "Requires=" notin u
    # The base's shell, never the store binary, which may predate it.
    let exec = u.split("ExecStart=")[1].split("\n")[0]
    # No outer timeout (A9 review round 20): an overrun is TimeoutStartSec=.
    # No ``-`` either: the boot-hold unit fails on any unexpected end
    # (decision 172 as amended 2026-11-21).
    check exec.startsWith("/bin/sh -c '") and "timeout -k" notin exec and
      "/repro/store" notin exec and "system addon" notin exec

suite "§13 decision 159: generation 0's upgrade path":
  test "an own profile without the unit gets it, rendered as a bootstrap would":
    let miss = missingGeneration0Objects(previousEngine)
    check miss.len == 2
    check miss[0].unit == BootHoldUnit
    check miss[0].content == bootHoldUnit()
    check miss[1].unit == BootConfirmUnit
    check miss[1].content == bootConfirmUnit(Exe)
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
    proc shaAt(p: string): string =
      for o in miss:
        if o.path == p: return sha256Hex(o.content)
    let up = addMissingGeneration0(previousEngine, miss,
      proc (p: string): tuple[present: bool; sha256: string] = (true, shaAt(p)),
      proc (p: string): string = shaAt(p))
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
    check probed.len == 3

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
    # ``daemon-reload`` answers from A9_RELOAD (0: reloaded).
    writeFile(result.bin / "systemctl", "#!/bin/sh\necho \"$@\" >> " &
      result.log & "\ncase \"$1\" in is-active) exit ${A9_SYSINIT:-3};; " &
      "daemon-reload) exit ${A9_RELOAD:-0};; esac\nexit 0\n")
    # sleep: the script's fail-closed wait, logged instead of waited for.
    writeFile(result.bin / "sleep", "#!/bin/sh\necho SLEEP \"$@\" >> " &
      result.log & "\nexit 0\n")
    for t in ["systemctl", "sleep"]:
      setFilePermissions(result.bin / t, {fpUserRead, fpUserWrite, fpUserExec})
  proc runScript(s: Sandbox; sysinitReached = false; reloadFails = false): int =
    ## The unit's own script, its paths moved under the sandbox.
    let script = bootHoldScript()
      .replace(BootHoldRecordPath, bootHoldRecordPath(s.state))
      .replace(BootHoldTextPath, bootHoldTextPath(s.state))
      .replace(BootHoldsWrittenList, s.written)
      .replace("/run/repro-addon", parentDir(s.written))
      .replace(RuntimeUnitDirPath, s.root)
      .replace(ConservativeHoldDir, parentDir(s.root) / "etc-systemd-system")
      # The host's tools by absolute path; the test's from PATH, with the
      # systemctl stand-in first.
      .replace("/usr/bin/", "")
    let f = parentDir(s.root) / "script.sh"
    writeFile(f, script)
    # The stand-in first, then the test's own tools (mkdir, cp).
    execShellCmd("env PATH=" & s.bin & ":" & getEnv("PATH") & " A9_SYSINIT=" &
      (if sysinitReached: "0" else: "3") & " A9_RELOAD=" &
      (if reloadFails: "1" else: "0") & " sh " & f & " >> " & s.log)
  test "the unit carries the script, each $ doubled for systemd":
    # One single-quoted argument: a quote inside it would end the quoting.
    check '\'' notin bootHoldScript()
    check ("/bin/sh -c '" & bootHoldScript().replace("$", "$$") & "'\n") in
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
    # A9 review round 20: no holds is a record of none, not no record.
    writeBootHoldRecord(s.state, [])
    check readFile(bootHoldRecordPath(s.state)) == ""
  test "at boot, the recorded holds are back before the one reload":
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.service.d/" & StartHoldName,
                                  "/run/systemd/system/a.socket.d/" & StartHoldName])
    # Lines the switch never writes steer nothing outside the root.
    writeFile(bootHoldRecordPath(s.state), readFile(bootHoldRecordPath(s.state)) &
      "../escape.d\n.hidden.d\nx/y.d\nnot-a-dir\n")
    check runScript(s) == 0
    # The minimal hold, written straight away (A9 review round 20).
    check readFile(s.root / "a.service.d" / StartHoldName) == MinimalHoldText
    check readFile(s.root / "a.socket.d" / StartHoldName) == MinimalHoldText
    check not fileExists(parentDir(s.root) / "escape.d" / StartHoldName)
    check not dirExists(s.root / ".hidden.d")
    check not dirExists(s.root / "not-a-dir")
    check readFile(s.written).splitLines().len == 3   # two paths and the end
    check readFile(s.log).count("daemon-reload") == 1
    check "skipped the record line ../escape.d" in readFile(s.log)
    check "held 2 unit drop-in directories, systemd reloaded" in readFile(s.log)
    check "SLEEP" notin readFile(s.log)
  test "nothing once sysinit.target is reached, said so":
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.service.d/" & StartHoldName])
    check runScript(s, sysinitReached = true) == 0
    check not dirExists(s.root)
    check "sysinit.target is already active" in readFile(s.log)
  test "a record of none holds nothing, said so":
    let s = setup()
    writeBootHoldRecord(s.state, [])
    check runScript(s) == 0
    check not dirExists(s.root / "a.socket.d")
    check "no unit is listed: nothing to hold" in readFile(s.log)
    check "daemon-reload" notin readFile(s.log)
  test "the script names every tool by absolute path":
    let sc = bootHoldScript()
    for tool in ["/usr/bin/systemctl is-active", "/usr/bin/mkdir -p",
                 "/usr/bin/cat ", "/usr/bin/sleep ",
                 "/usr/bin/timeout 30 /usr/bin/systemctl daemon-reload",
                 "/usr/bin/ls -1 "]:
      check tool in sc
    # No copy and no digest of the hold text before the writes (A9 review
    # round 20).
    check "/usr/bin/cp " notin sc
    check "sha256sum" notin sc
    check "set -f;" in sc
  test "a planted hold text is never copied: the minimal hold on every recorded unit":
    # A9 review round 16, finding 10, and round 20: the text is not read.
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    writeFile(bootHoldTextPath(s.state), "[Unit]\nDescription=planted\n")
    check runScript(s) == 0
    let h = readFile(s.root / "a.socket.d" / StartHoldName)
    check "AssertPathExists=!/" in h
    check "planted" notin h
  test "a drop-in directory that is a link is skipped":
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.socket.d/" & StartHoldName,
                                  "/run/systemd/system/b.socket.d/" & StartHoldName])
    createDir(s.root)
    createSymlink("/tmp", s.root / "b.socket.d")
    check runScript(s) == 0
    check fileExists(s.root / "a.socket.d" / StartHoldName)
    check not fileExists("/tmp/" & StartHoldName)
    # A hold not written fails closed (A9 review round 20): the script
    # waits for TimeoutStartSec= to fail the unit.
    check "1 of the holds could not be written" in readFile(s.log)
    check "SLEEP" in readFile(s.log)
  test "a record that is a link: every socket, timer and path unit held, and exit 0":
    # A9 review round 17, finding 9: hold conservatively, never fail.
    let s = setup()
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    let rec = bootHoldRecordPath(s.state)
    moveFile(rec, rec & ".real")
    createSymlink(rec & ".real", rec)
    let etc = parentDir(s.root) / "etc-systemd-system"
    createDir(etc)
    for n in ["x.socket", "y.timer", "z.path", "w.service", "v.target",
              "ssh.socket", "repro-agent-fetch.timer"]:
      writeFile(etc / n, "[Unit]\n")
    check runScript(s) == 0
    for n in ["x.socket", "y.timer", "z.path"]:
      check fileExists(s.root / (n & ".d") / StartHoldName)
    # A9 review round 18, L2: never an essential unit (§13 decision 177),
    # read from A13's list.
    for n in ["w.service", "v.target", "a.socket", "ssh.socket",
              "repro-agent-fetch.timer"]:
      check not dirExists(s.root / (n & ".d"))
    check readFile(s.log).count("daemon-reload") == 1
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

suite "§13 decision 164: the re-assert unit is pointed at the upgrading engine":
  const NewExe = "/repro/store/prefixes/repro-addon/0.2.99-new/bin/repro"
  let curUnit = unitContentOf(current, ReassertUnit)
  let sha = sha256Hex(curUnit)
  let confirmSha = sha256Hex(unitContentOf(current, BootConfirmUnit))
  proc onDisk(p: string): tuple[present: bool; sha256: string] =
    if p == unitPath(ReassertUnit): (true, sha)
    elif p == unitPath(BootConfirmUnit): (true, confirmSha)
    else: (false, "")
  proc recordedAs(p: string): string = onDisk(p).sha256
  test "the add-on's own units, on disk and in the ledger, are re-rendered":
    let r = repointEngine(current, NewExe, [Exe], onDisk, recordedAs)
    check r.changed
    check r.exe == NewExe
    check reassertExeOf(unitContentOf(r.own, ReassertUnit)) == NewExe
    check unitContentOf(r.own, ReassertUnit) == reassertUnit(NewExe)
    # The boot-confirm unit moves with it (§13 decision 157); nothing else
    # of generation 0 changes.
    check unitContentOf(r.own, BootConfirmUnit) == bootConfirmUnit(NewExe)
    check r.own.replace(unitContentOf(r.own, ReassertUnit), "").replace(
            unitContentOf(r.own, BootConfirmUnit), "") ==
          current.replace(curUnit, "").replace(unitContentOf(current, BootConfirmUnit), "")
  test "idempotent: units that already run this engine are left alone":
    check not repointEngine(current, Exe, [Exe], onDisk, recordedAs).changed
  test "a foreign unit, or one the ledger does not record, is refused":
    for (d, rc) in [(sha256Hex("operator's"), sha), (sha, ""), ("", "")]:
      let dd = d
      let rr = rc
      expect ValueError:
        discard repointEngine(current, NewExe, [Exe],
          proc (p: string): tuple[present: bool; sha256: string] =
            if p == unitPath(ReassertUnit): (true, dd) else: onDisk(p),
          proc (p: string): string =
            if p == unitPath(ReassertUnit): rr else: recordedAs(p))
  test "no unit installed: nothing to keep, so the applying image or nothing":
    # A9 review round 17: the units an upgrade adds run the applying
    # engine's image; with none (the dynamic engine and no static image),
    # the own profile is left as it is.
    check not repointEngine(current, "", [Exe], absent, unrecorded).changed
    let r = repointEngine(current, NewExe, [Exe], absent, unrecorded)
    check reassertExeOf(unitContentOf(r.own, ReassertUnit)) == NewExe

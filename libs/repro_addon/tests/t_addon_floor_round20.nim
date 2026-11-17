## The add-on after the A9 review's round 20 (ReproOS Add-On Mode spec
## §6.2 step 4, §10.1; the boot-hold unit's fail-closed design the owner
## approved on 2026-11-17, recorded with the boot-hold unit's ordering
## decision in §13):
##
## - the boot-hold script, run with its paths moved into a sandbox: a
##   pending marker with no record holds conservatively; a reload that
##   fails, or a hold that cannot be written, fails closed (the script
##   waits for TimeoutStartSec=); every hold is written before the one
##   slow step, the reload; every exit path says why;
## - the unit has no outer ``timeout``; ``-`` covers exit codes only;
## - the pending marker is never on disk without the record;
## - M-1: the ``systemd.systemDropIn`` form counts as the profile's unit
##   in both halves of the ordering refusal;
## - LOW: ``Accept=`` is read for a socket the profile changes only by a
##   drop-in, and as systemd reports it for the host's own files; the
##   preflight's static-image check is wired into ``runPreflight``.
##
## Falsifying builds, red here: ``boot-hold-record-absent-skips``,
## ``boot-hold-reload-failure-passes``, ``boot-hold-holds-after-slow-step``,
## ``boot-hold-outer-timeout``, ``boot-hold-marker-without-record``,
## ``boot-hold-systemdropin-unchecked``,
## ``boot-hold-systemdropin-effective-unchecked``,
## ``accept-dropin-only-sockets-skipped``, ``bootstrap-accepts-dynamic``,
## ``boot-hold-minimal-hold-judged``.
##
## *Mocking.* The script runs under the real ``/bin/sh`` with ``systemctl``
## and ``sleep`` stand-ins on PATH: the stand-in ``systemctl`` reports
## ``sysinit.target`` inactive, and on ``daemon-reload`` logs how many holds
## are on disk and exits with the status the case asks for; the stand-in
## ``sleep`` logs the fail-closed wait instead of waiting 120 s. The VM gate
## ``t_e2e_addon_boot_hold_is_required`` runs the same script on a real
## boot. The effective pass is given ``systemctl show`` text per unit; the
## preflight runs on this host with an ELF written here.

import std/[os, osproc, sets, strutils, tempfiles, unittest]

import repro_infra
import repro_infra/errors
import repro_addon/addon_apply
import repro_addon/boot_holds
import repro_addon/effective_floor
import repro_addon/generation0
import repro_addon/preflight
import repro_addon/static_tree

type Sandbox = tuple[tmp, state, root, written, etc, bin, log: string]

proc setup(): Sandbox =
  let tmp = createTempDir("a9r20-", "-holds")
  result = (tmp, tmp / "state", tmp / "run-systemd-system",
            tmp / "run-addon" / "boot-holds-written", tmp / "etc-systemd-system",
            tmp / "bin", tmp / "log")
  createDir(result.bin)
  createDir(result.etc)
  writeFile(result.log, "")
  # daemon-reload logs the holds on disk when it runs, then answers with
  # A9_RELOAD (0: reloaded).
  writeFile(result.bin / "systemctl", "#!/bin/sh\n" &
    "case \"$1\" in is-active) exit 3;; daemon-reload) echo RELOAD-SEES " &
    "$(ls " & result.root & "/*.d/* 2>/dev/null | wc -l) >> " & result.log &
    "; exit ${A9_RELOAD:-0};; esac\nexit 0\n")
  writeFile(result.bin / "sleep", "#!/bin/sh\necho SLEEP \"$@\" >> " &
    result.log & "\nexit 0\n")
  for t in ["systemctl", "sleep"]:
    setFilePermissions(result.bin / t, {fpUserRead, fpUserWrite, fpUserExec})

proc run(s: Sandbox; reloadFails = false): string =
  ## The unit's own script with its paths moved under the sandbox; its
  ## output and the stand-ins' lines.
  let script = bootHoldScript()
    .replace(BootHoldRecordPath, bootHoldRecordPath(s.state))
    .replace(BootHoldsWrittenList, s.written)
    .replace("/run/repro-addon", parentDir(s.written))
    .replace(RuntimeUnitDirPath, s.root)
    .replace(ConservativeHoldDir, s.etc)
    .replace("/usr/bin/", "")
  writeFile(s.tmp / "script.sh", script)
  discard execShellCmd("env PATH=" & s.bin & ":" & getEnv("PATH") &
    " A9_RELOAD=" & (if reloadFails: "1" else: "0") & " sh " &
    s.tmp / "script.sh" & " >> " & s.log & " 2>&1")
  readFile(s.log)

suite "A9 review round 20: the boot-hold unit fails closed":
  test "a pending marker with no record holds every activator, said so":
    let s = setup()
    defer: removeDir(s.tmp)
    for n in ["x.socket", "y.timer", "w.service"]:
      writeFile(s.etc / n, "[Unit]\n")
    let o = run(s)
    checkpoint o
    check "the pending marker is there but the record is absent" in o
    check fileExists(s.root / "x.socket.d" / StartHoldName)
    check fileExists(s.root / "y.timer.d" / StartHoldName)
    check not dirExists(s.root / "w.service.d")
    check "held 2 unit drop-in directories, systemd reloaded" in o
  test "a reload that fails is not success: the script waits to fail the unit":
    let s = setup()
    defer: removeDir(s.tmp)
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    let o = run(s, reloadFails = true)
    checkpoint o
    check "wrote 1 holds but systemd was not reloaded" in o
    check "SLEEP 120" in o
    check "systemd reloaded" notin o
  test "every hold is written before the one slow step, and listed before it is written":
    let s = setup()
    defer: removeDir(s.tmp)
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.socket.d/" & StartHoldName,
                                  "/run/systemd/system/b.timer.d/" & StartHoldName,
                                  "/run/systemd/system/c.service.d/" & StartHoldName])
    let o = run(s)
    checkpoint o
    check o.count("RELOAD-SEES") == 1
    check "RELOAD-SEES 3" in o
    check readFile(s.written).splitLines().len == 4
    for d in ["a.socket.d", "b.timer.d", "c.service.d"]:
      check readFile(s.root / d / StartHoldName) == MinimalHoldText
  test "a hold whose directory cannot be made fails closed":
    let s = setup()
    defer: removeDir(s.tmp)
    writeBootHoldRecord(s.state, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    createDir(s.root)
    writeFile(s.root / "a.socket.d", "a file where the directory goes")
    let o = run(s)
    checkpoint o
    check "cannot make" in o
    check "SLEEP 120" in o
  test "the minimal hold the boot writes is the add-on's own to the next check":
    # Found by the hard-reset gate: a replay's or a revert's check after a
    # boot that put the minimal hold back refused the held unit
    # (``rule:file-keys``) and left it held by the revert.
    let p = RuntimeUnitDirPath & "/a9.service.d/" & StartHoldName
    check MinimalHoldText == MinimalStartHoldText
    check isAddonHold(p, MinimalHoldText)
    check isAddonHold(p, StartHoldText)
    check not isAddonHold(p, MinimalHoldText & "ExecStart=/bin/sh\n")
    check not isAddonHold("/etc/systemd/system/a9.service.d/" & StartHoldName, MinimalHoldText)
  test "the unit has no outer timeout; TimeoutStartSec= bounds it":
    let u = bootHoldUnit()
    check "ExecStart=-/bin/sh -c '" in u
    check "timeout -k" notin u
    check "TimeoutStartSec=" & $BootHoldTimeoutSec & "\n" in u
    check BootHoldTimeoutSec * 2 > BootHoldTimeoutSec

suite "A9 review round 20: the marker never lacks the record":
  test "a marker written with no record gets a record of none first":
    let d = createTempDir("a9r20-", "-state")
    defer: removeDir(d)
    writePendingMarker(d, PendingMarker(fromGeneration: "g0", step: ssRealise))
    check fileExists(bootHoldRecordPath(d))
    check readFile(bootHoldRecordPath(d)) == ""
  test "a record already there is kept":
    let d = createTempDir("a9r20-", "-state")
    defer: removeDir(d)
    writeBootHoldRecord(d, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    writePendingMarker(d, PendingMarker(fromGeneration: "g0", step: ssRealise))
    check readBootHoldRecord(d) == @["a.socket.d"]
  test "holds lifted while pending leave a record of none; the marker goes first":
    let d = createTempDir("a9r20-", "-state")
    defer: removeDir(d)
    writeBootHoldRecord(d, ["/run/systemd/system/a.socket.d/" & StartHoldName])
    writePendingMarker(d, PendingMarker(fromGeneration: "g0", step: ssRealise))
    clearBootHoldRecord(d)
    check fileExists(bootHoldRecordPath(d)) and readFile(bootHoldRecordPath(d)) == ""
    clearPendingMarker(d)
    check not hasPendingMarker(d)
    check not fileExists(bootHoldRecordPath(d))

proc parsed(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

proc systemDropIn(unit, body: string): string =
  "systemd.systemDropIn {\n  unit = \"" & unit & "\"\n  name = \"a9\"\n" &
    "  content = \"" & body & "\"\n}\n"

suite "A9 review round 20, M-1: the systemd.systemDropIn form":
  test "the parse half: Conflicts= naming the boot-hold unit is refused":
    check "names " & BootHoldUnit & " in Conflicts=" in
      parsed(systemDropIn("cron.service", "[Unit]\nConflicts=" & BootHoldUnit & "\n"))
  test "the parse half: a base unit ordered before systemd-remount-fs.service":
    check "an ordering cycle" in
      parsed(systemDropIn("cron.service", "[Unit]\nBefore=systemd-remount-fs.service\n"))
  test "the effective half judges the unit it changes":
    let res = @[SystemResource(kind: srkSystemdSystemDropIn, diUnit: "cron.service",
                               diName: "a9", diContent: "[Unit]\nBefore=zfs-mount.service\n")]
    let p = everyUnitBootHoldProblems(res, initHashSet[string](),
      proc (n: string): tuple[ok: bool; show: ShowProps] =
        (true, parseShow(if n == "cron.service":
                           "After=sysinit.target\nBefore=zfs-mount.service\n"
                         else: "After=sysinit.target\n")),
      proc (u: string): seq[string] =
        if u == "zfs-mount.service": @["local-fs.target"] else: @[])
    checkpoint p.join("\n")
    check p.len == 1 and "cron.service" in p[0] and "boot-hold-cycle" in p[0]

suite "A9 review round 20, LOW: Accept= of a socket the profile only changes":
  let svc = "systemd.systemUnit {\n  name = \"a9a@.service\"\n  content = \"" &
    "[Service]\nType=oneshot\nExecStart=/bin/true\nStandardInput=socket\n\"\n" &
    "  floorExceptions = [\"serviceFloor: a fixture\"]\n  enabled = false\n}\n"
  test "a drop-in (either form) setting Accept=yes on a base socket":
    let a = acceptSocketTemplates(parseAddOnUserProfile(svc &
      "systemd.systemUnit {\n  name = \"a9a.socket\"\n  collision = \"dropIn\"\n" &
      "  content = \"[Socket]\nAccept=yes\n\"\n}\n"))
    check "a9a@.service" in a
    let b = acceptSocketTemplates(parseAddOnUserProfile(svc &
      systemDropIn("a9a.socket", "[Socket]\nAccept=yes\n")))
    check "a9a@.service" in b
  test "Accept=yes from the host's own files, as systemd reports it":
    let p = parseAddOnUserProfile(svc &
      systemDropIn("a9a.socket", "[Socket]\nBacklog=8\n"))
    check "a9a@.service" notin acceptSocketTemplates(p)
    check "a9a@.service" in acceptSocketTemplates(p,
      proc (sk: string): bool = sk == "a9a.socket")

suite "A9 review round 20, LOW: the static-image check is wired":
  test "runPreflight with a dynamically linked binary is not compatible":
    let d = createTempDir("a9r20-", "-elf")
    defer: removeDir(d)
    var b = newSeq[uint8](64 + 56 * 2)
    b[0] = 0x7f; b[1] = uint8('E'); b[2] = uint8('L'); b[3] = uint8('F')
    b[4] = 2; b[5] = 1; b[6] = 1
    proc put(off, n: int; v: uint64) =
      for i in 0 ..< n: b[off + i] = uint8((v shr (8 * i)) and 0xff)
    put(0x10, 2, 2); put(0x20, 8, 64); put(0x36, 2, 56); put(0x38, 2, 2)
    put(64, 4, 3); put(64 + 56, 4, 1)          # PT_INTERP, PT_LOAD
    var f = open(d / "dynamic", fmWrite)
    discard f.writeBytes(b, 0, b.len)
    f.close()
    let r = runPreflight(PreflightInputs(binaryPath: d / "dynamic"))
    var seen = false
    for c in r.checks:
      if c.id == "addon-binary-static":
        seen = true
        check c.verdict == vFail
    check seen
    check not r.compatible

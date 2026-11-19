## Gate ``e2e_arch_addon_root_snapshot_setting`` (milestone AR4; spec
## ReproOS-Add-On-Mode §6.4, §7.2, §8.5, §12.2; §13 decisions 90, 100, 101,
## 105, 116; threat model T61, G51).
##
## **On the ext4 guest** (no snapper configuration for ``/``):
##
## - ``rootSnapshot = "required"`` refuses the apply with
##   ``EAddOnRootSnapshot`` before anything is written (fingerprint and
##   ledger unchanged);
## - ``ifConfigured`` applies, and both the plan and the apply say that no
##   second way back exists.
##
## **On the Omarchy VM** (snapper configured for ``/``, ``NUMBER_LIMIT=5``):
##
## - an apply refused at plan time (a file Omarchy's scripts write, without
##   ``overrideBaseLayer``: ``EAddOnBaseLayerOwned``) takes no snapshot;
## - generation 1 (``required``) takes one: snapper lists it with the
##   ``repro-addon=<key>`` userdata and an empty cleanup algorithm, and
##   generation 1's log and ``repro system addon root-snapshots`` name it;
## - six ``omarchy update`` runs, each of which takes Omarchy's own numbered
##   snapshot and runs ``snapper cleanup number``, leave it in place (and,
##   the vacuity guard, did delete Omarchy's oldest);
## - generations 2 and 3 take theirs; dropping generation 1 from retention
##   (``repro system addon retention --keep-generations 0 --keep-days 0``,
##   which keeps the current and the previous generation) deletes exactly
##   generation 1's snapshot;
## - a generation with no ``network`` object refused at step 2 (an
##   exclusive unit whose instance ignores SIGTERM: ``EAddOnExclusiveOverlap``)
##   deletes the snapshot it took as it is undone, and writes no
##   ``rolled-back`` record (A4's path);
## - a snapshot carrying the ``repro-addon`` userdata that this state never
##   recorded is planted; uninstall deletes every ``repro-addon`` snapshot,
##   that one too, and no other;
## - and with Omarchy's snapshots taken during the run, the base
##   fingerprint after uninstall equals the one before bootstrap: the
##   ``btrfs-subvolumes`` component leaves out the snapshots the add-on did
##   not create (§12.2, §13 decision 100).
##
## The ``omarchy update`` runs are Omarchy's own command, run as the
## Omarchy account in a login session (given passwordless sudo by the test
## bed before the baseline: the update asks for it) with
## ``OMARCHY_ALLOW_DIRECT_PACMAN=1``
## (the guest's pacman reads the capture cache, spec §7.9 and §12.1). Two
## runs before the baseline settle what an update does to the base once,
## and a control run after it must leave the fingerprint as it is.
## What this gate needs of each run is its snapshot step; the run's exit
## status and its last lines are recorded.
##
## Falsifying mutation: ``REPRO_ADDON_MUTATION=snapshot-cleanup-number``
## takes the snapshot with ``--cleanup-algorithm number``, so the updates'
## ``cleanup number`` deletes it and the gate goes red on the Omarchy VM
## (the ext4 guest takes no snapshot: green there). Judged by
## ``arch_gate_support.falsifierVerdict``.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-ext4-amd64,omarchy-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_root_snapshot_setting``).
##
## *Mocking.* None: the real guests, snapper and snapperd, the real
## ``omarchy update``, and the real static add-on binary.

import std/[algorithm, json, os, sequtils, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const
  Gate = "e2e_arch_addon_root_snapshot_setting"
  OmarchyUpdates = 6
  StubbornPath = "/usr/local/bin/repro-ar4-stubborn"
  StubbornScript = "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 0.2; done\n"
  StubbornUnit = "repro-ar4-exclusive.service"
  UpdateSudoers = "/etc/sudoers.d/90-repro-gate-omarchy-update"

proc stubbornUnit(gen: string): string =
  ## An exclusive unit whose instance ignores SIGTERM and may not be
  ## killed: a definition change cannot confirm it stopped, so the switch
  ## is refused at step 2 (spec §7.3).
  "systemd.systemUnit {\n" & FixtureFloorWaiver & "  name = \"" & StubbornUnit &
    "\"\n  content = \"[Unit]\nDescription=AR4 exclusive fixture " & gen &
    "\nX-Repro-Exclusive=true\n\n[Service]\nExecStart=" & StubbornPath & " " &
    gen & "\nTimeoutStopSec=3\nSendSIGKILL=no\n\n[Install]\n" &
    "WantedBy=multi-user.target\n\"\n}\n\n"

proc omarchyUpdate(g: Guest; account: string): tuple[rc: int; tail: string] =
  ## One ``omarchy update -y`` as ``account``, in a login session.
  let r = g.exec("systemd-run --wait --pipe -q --uid=" & account &
    " -p PAMName=login -E OMARCHY_ALLOW_DIRECT_PACMAN=1 -E HOME=/home/" &
    account & " bash -lc 'timeout 1200 omarchy update -y </dev/null' " &
    "> /root/addon/omarchy-update.log 2>&1; echo $?", timeoutSec = 1500)
  let tail = g.exec("sed 's/\\x1b\\][^\\\\]*\\\\//g; s/\\x1b\\[[0-9;]*m//g' " &
    "/root/addon/omarchy-update.log | grep -v '^\\s*$' | tail -8").stdout
  ((try: parseInt(r.stdout.strip()) except ValueError: -1), tail)

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  case mut
  of "snapshot-cleanup-number":
    if not isOmarchyBase(b):
      return Falsifier(green: true, mustRunGreen: @["bootstrap",
        "required: refused before anything is written", "uninstall"])
    Falsifier(
      required: @["omarchy updates: generation 1's snapshot is still there"],
      mayBeRed: @[
        "generation 1: snapper lists it with the add-on's userdata and no cleanup algorithm",
        "omarchy updates: the add-on's snapshots are owned as before",
        "retention: generation 1's snapshot, and only it, is deleted"],
      mustRunGreen: @["bootstrap", "generation 1: applied, taking its snapshot",
        "control: an omarchy update alone leaves the base fingerprint as it is",
        "omarchy updates: each took Omarchy's numbered snapshot",
        "vacuity guard: the updates' cleanup deleted Omarchy's oldest",
        "generation 2: applied", "generation 3: applied", "uninstall",
        "uninstall: every repro-addon snapshot is gone, and no other",
        "base fingerprint after uninstall == before bootstrap"])
  else: raise unknownMutation(Gate, mut)

proc ext4Leg(g: Guest; repro: string; step: StepFn) =
  g.settleBaseline(step)
  let f0 = g.fingerprintArch(repro)
  if not g.bootstrapArch(repro, step).ok: return
  let exe = g.gen0ReproExe()
  let body = fixtureUnit(exe) & "\n" & fixtureFile("fixture = 1\n")
  let before = g.fingerprintArch(repro)
  let lBefore = g.ledgerOf()
  let rq = g.applyProfile(repro, "required", rootSnapshotStanza("required", "") & body)
  step("required: refused before anything is written",
       rq.exitCode != 0 and "EAddOnRootSnapshot" in rq.stdout & rq.stderr and
         "no configuration for /" in rq.stdout & rq.stderr and
         identityReport(before, g.fingerprintArch(repro)).ok and
         g.ledgerOf() == lBefore, "exit " & $rq.exitCode & "\n" & rq.stdout & rq.stderr)
  let p = g.planProfile(repro, "ifconfigured-plan", rootSnapshotStanza("ifConfigured", "") & body)
  step("ifConfigured: the plan says no second way back exists",
       p.exitCode == 0 and "no second way back exists" in p.stdout, p.stdout & p.stderr)
  let a = g.applyProfile(repro, "ifconfigured", rootSnapshotStanza("ifConfigured", "") & body)
  step("ifConfigured: applies, and says no second way back exists",
       a.exitCode == 0 and "no second way back exists" in a.stdout and
         "root snapshot taken" notin a.stdout, a.stdout & a.stderr)
  let un = g.exec(repro & " system addon uninstall")
  step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  let ident = identityReport(f0, g.fingerprintArch(repro))
  step("base fingerprint after uninstall == before bootstrap", ident.ok, ident.text)

proc omarchyLeg(g: Guest; b: BaseImage; repro: string; step: StepFn;
                record: JsonNode) =
  let account = accountFor(b)
  # `omarchy update` asks for the account's password through sudo (the
  # installer gave the account a password-protected sudo): passwordless
  # sudo for it, written here as part of the base, before the baseline.
  discard g.run("printf '" & account & " ALL=(ALL:ALL) NOPASSWD: ALL\\n' > " &
    UpdateSudoers & " && chmod 0440 " & UpdateSudoers & " && visudo -c >/dev/null")
  writeFile(g.runDir / "stubborn.sh", StubbornScript)
  g.copyTo(g.runDir / "stubborn.sh", StubbornPath)
  discard g.run("chmod 0755 " & StubbornPath)
  # Updates before the baseline: what an update changes in the base once
  # (the first removes orphan packages; a login session starts the user
  # database's units), so the six later ones change nothing the
  # fingerprint records. The control after the baseline shows they do not.
  for i in 1 .. 2:
    let warm = g.omarchyUpdate(account)
    record["warmUpUpdate" & $i] = %*{"exit": warm.rc, "tail": warm.tail}
  # The base's own snapper-cleanup.timer starts snapper-cleanup.service ten
  # minutes after boot, and that unit `Requires=nss-user-lookup.target`
  # (snapper's packaging): run once before the baseline, so the timer's
  # first firing during the gate changes nothing the fingerprint records.
  discard g.run("systemctl start snapper-cleanup.service", timeoutSec = 600)
  g.settleBaseline(step)
  let f0 = g.fingerprintArch(repro, account)
  let ctl = g.omarchyUpdate(account)
  let fCtl = identityReport(f0, g.fingerprintArch(repro, account), [SnapperdActivation])
  step("control: an omarchy update alone leaves the base fingerprint as it is",
       ctl.rc == 0 and fCtl.ok, "exit " & $ctl.rc & "\n" & fCtl.text)
  if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return
  let exe = g.gen0ReproExe()
  proc body(n: int): string = fixtureUnit(exe) & "\n" & fixtureFile("fixture = " & $n & "\n")
  proc stanza(): string = rootSnapshotStanza("required", account)
  proc snapshotOf(gen: string): int = g.loggedSnapshot(gen).number
  # --- A plan-time refusal takes none.
  let rowsBefore = g.snapperRows()
  let refused = g.applyProfile(repro, "refused",
    rootSnapshotStanza("required", account, @[FixturePrefix, SudoersFile]) &
      body(0) & sudoersRes())
  step("an apply refused at plan time takes no snapshot",
       refused.exitCode == 2 and "EAddOnBaseLayerOwned" in refused.stdout & refused.stderr and
         numbersOf(g.snapperRows()) == numbersOf(rowsBefore),
       "exit " & $refused.exitCode & "\n" & refused.stdout & refused.stderr &
         "\n" & g.run("snapper -c root list"))
  # --- Generation 1 takes one.
  let r1 = g.applyProfile(repro, "g1", stanza() & body(1))
  step("generation 1: applied, taking its snapshot",
       r1.exitCode == 0 and "root snapshot taken: root#" in r1.stdout, r1.stdout & r1.stderr)
  let gen1 = g.currentGeneration()
  let s1 = g.loggedSnapshot(gen1)
  var row1 = SnapperRow()
  for r in g.snapperRows():
    if r.number == s1.number: row1 = r
  step("generation 1: snapper lists it with the add-on's userdata and no cleanup algorithm",
       s1.number > 0 and row1.userdata == "repro-addon=" & s1.key and row1.cleanup == "",
       $s1 & " " & $row1 & "\n" & g.run("snapper -c root list"))
  let owned1 = g.run(repro & " system addon root-snapshots")
  step("generation 1: root-snapshots names its owner",
       ("root#" & $s1.number & " repro-addon=" & s1.key & " owner=generation " & gen1) in owned1,
       owned1)
  # --- Six omarchy updates leave it in place.
  var took = true
  var updates = newJArray()
  let omarchyBefore = g.snapperRows().filterIt(it.cleanup == "number")
  for i in 1 .. OmarchyUpdates:
    let before = g.snapperRows()
    let u = g.omarchyUpdate(account)
    let after = g.snapperRows()
    var newest = 0
    for r in after:
      if r.cleanup == "number" and r.number notin numbersOf(before):
        newest = max(newest, r.number)
    updates.add(%*{"run": i, "exit": u.rc, "newNumbered": newest, "tail": u.tail})
    if newest == 0: took = false
  record["omarchyUpdates"] = updates
  step("omarchy updates: each took Omarchy's numbered snapshot", took, $updates)
  let numbered = g.snapperRows().filterIt(it.cleanup == "number")
  step("vacuity guard: the updates' cleanup deleted Omarchy's oldest",
       numbered.len <= 5 and numbered.len + omarchyBefore.len < OmarchyUpdates + omarchyBefore.len,
       g.run("snapper -c root list"))
  step("omarchy updates: generation 1's snapshot is still there",
       s1.number in numbersOf(g.addonRows()), g.run("snapper -c root list"))
  let owned2 = g.exec(repro & " system addon root-snapshots").stdout
  step("omarchy updates: the add-on's snapshots are owned as before",
       "missing:" notin owned2 and ("owner=generation " & gen1) in owned2, owned2)
  # --- Generations 2 and 3, then retention drops 1.
  let r22 = g.applyProfile(repro, "g2", stanza() & body(2))
  step("generation 2: applied", r22.exitCode == 0, r22.stdout & r22.stderr)
  let gen2 = g.currentGeneration()
  let r3 = g.applyProfile(repro, "g3", stanza() & body(3))
  step("generation 3: applied", r3.exitCode == 0, r3.stdout & r3.stderr)
  let gen3 = g.currentGeneration()
  let allBefore = g.snapperRows()
  let ret = g.exec(repro & " system addon retention --keep-generations 0 --keep-days 0")
  let allAfter = g.snapperRows()
  let gone = numbersOf(allBefore).filterIt(it notin numbersOf(allAfter))
  # Generation 1 (and generation 0, which took none) is outside the
  # policy: it loses its snapshot. Generations 2 and 3 keep theirs, and
  # every one of Omarchy's stays.
  step("retention: generation 1's snapshot, and only it, is deleted",
       ret.exitCode == 0 and gone == @[s1.number] and
         snapshotOf(gen2) in numbersOf(allAfter) and snapshotOf(gen3) in numbersOf(allAfter),
       "deleted " & $gone & ", expected " & $s1.number & "\n" & ret.stdout & ret.stderr)
  # --- A switch refused at step 2 (no network object) deletes its own.
  let rs = g.applyProfile(repro, "g-exclusive", stanza() & body(1) & stubbornUnit("e1"))
  step("generation with the exclusive unit: applied", rs.exitCode == 0, rs.stdout & rs.stderr)
  let genE = g.currentGeneration()
  let addonBefore = numbersOf(g.addonRows())
  let logsBefore = g.run("ls /var/lib/repro/system/generations | sort")
  let r2 = g.applyProfile(repro, "g-refused-at-step-2", stanza() & body(1) & stubbornUnit("e2"))
  let said = r2.stdout & r2.stderr
  step("a switch refused at step 2 is refused with EAddOnExclusiveOverlap",
       r2.exitCode == 2 and "EAddOnExclusiveOverlap" in said and
         "root snapshot taken" notin r2.stdout, "exit " & $r2.exitCode & "\n" & said)
  # The refusal names the snapshot its undo deleted: without that line
  # the unchanged snapshot set below could also mean none was taken
  # (snapper reuses the highest number, so numbering cannot tell).
  step("the refused switch deleted its snapshot as it was undone",
       "deleted the refused switch's root snapshot root#" in said and
         numbersOf(g.addonRows()) == addonBefore and g.currentGeneration() == genE and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0,
       g.run("snapper -c root list") & "\n" & said)
  let rolled = g.exec("grep -la 'rolled-back' /var/lib/repro/system/generations/*/log/apply.log").stdout
  step("the refused switch wrote no rolled-back record",
       rolled.strip().len == 0 and g.run("ls /var/lib/repro/system/generations | sort") == logsBefore,
       rolled)
  discard g.run("systemctl kill -s KILL " & StubbornUnit & "; pkill -KILL -f '^/bin/sh " &
                StubbornPath & "' ; true")
  # --- Uninstall: every repro-addon snapshot, recorded or not, and no other.
  let planted = g.run("snapper -c root create --cleanup-algorithm '' --description " &
    "'not recorded by the add-on' --userdata repro-addon=planted --print-number").strip()
  let foreign = g.snapperRows().filterIt(not it.isAddonRow)
  let un = g.exec(repro & " system addon uninstall")
  step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  step("uninstall: every repro-addon snapshot is gone, and no other",
       g.addonRows().len == 0 and
         numbersOf(g.snapperRows()) == numbersOf(foreign) and planted.len > 0,
       "planted " & planted & "\n" & g.run("snapper -c root list"))
  let ident = identityReport(f0, g.fingerprintArch(repro, account),
                             [SnapperdActivation])
  step("base fingerprint after uninstall == before bootstrap", ident.ok, ident.text)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if isOmarchyBase(b): g.omarchyLeg(b, repro, step, record)
    else: g.ext4Leg(repro, step)
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
  test "rootSnapshot: refused or reported without snapper; on Omarchy kept, deleted and swept as the spec says":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if not (isOmarchyBase(b) or archVariantOf(b) == avExt4):
          failures.add(b.name & ": " & Gate & " runs on the ext4 guest and the Omarchy VM")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        if isOmarchyBase(b): record["omarchy"] = omarchyRecordBase()
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(Gate, record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

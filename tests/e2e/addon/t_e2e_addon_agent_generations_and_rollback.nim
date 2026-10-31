## Gate ``e2e_addon_agent_generations_and_rollback`` (spec §7.4, §7.5, §9,
## §9.3; reprobuild-pm issue
## 2026-10-31-addon-deploy-agent-applies-bypass-the-addon-switch-so-rollback-cannot-reach-them).
##
## The deploy agent on an add-on host applies through the add-on switch:
##
## 1. *migration restarts nothing* (c). The guest is put in the state the
##    rpi2 dogfood host was in: an agent that applied outside the switch
##    (its generation and sequence floor in /var/lib/repro/agent/state, its
##    units written and running, unknown to the add-on ledger) and only
##    generation 0 in /var/lib/repro/system. The first tick of the new
##    binary takes it over: an add-on generation records the agent
##    generation it migrated, and neither unit is restarted (same MainPID,
##    same ActiveEnterTimestamp).
## 2. *an agent apply commits an add-on generation* (a). Manifest 2 changes
##    one unit. The tick commits a generation under /var/lib/repro/system
##    whose ``addon-agent`` record carries the manifest's deploymentId and
##    sequence; the changed unit runs the new content, the unchanged one was
##    not restarted.
## 3. *a rollback re-applies and pauses the agent* (b, d). `repro system
##    rollback` to the migrated generation brings the old content back,
##    leaves the unchanged unit running untouched, and writes the pause
##    marker; the next tick reports ``aoPaused`` (exit 0) and changes
##    nothing.
## 4. *rolling forward again* (d) to manifest 2's generation also leaves the
##    unchanged unit untouched; `repro system addon resume` clears the
##    pause, and the next tick converges.
## 5. *generation-0 objects* (§9, "Generation-0 objects a profile
##    supersedes"). Like rpi2's, the profile declares /etc/repro/caches.conf
##    with other content than generation 0's, which the legacy agent wrote
##    over it (ledger drift), and the deploy-signer anchors byte for byte.
##    The migration supersedes both without a refusal: caches.conf keeps the
##    profile's bytes and has one ledger entry, the profile's (collision
##    `supersede`); the anchors are not written (same inode, same mtime).
##    A rollback to generation 0 puts generation 0's caches.conf back.
##
## keep-svc `depends_on` a file the migration adopts (rpi2's Alertmanager
## and its alertmanager.yml), so step 1 also shows that an adoption is not a
## change for a dependent.
##
## The fixture carries rpi2's kind mix (reprobuild-pm issue
## 2026-10-31-addon-switch-refuses-kinds-the-spec-lists-as-valid): a
## `systemd.systemTimer` running with its oneshot service, a `passwd.group`
## whose live members include one the profile does not name and the
## `passwd.user` it does, and a `linux.addOnTool` from a closure seeded into
## the deb cache. The migration adopts them as they are: the timer is not
## restarted, the extra member stays, the tool's files are not rewritten.
## The final rollback to generation 0 hands the adopted timer and tool
## files back as found (§4.2) and keeps both accounts (§6.4). At
## 59c075685f the switch refused the timer kind, and the plan and the
## migration both failed.
##
## At reprobuild 3a1068e25b, before the change, step 1 committed no add-on
## generation (the tick reported aoConverged and did nothing), step 2's
## generation carried no agent record, and step 3 wrote no pause marker:
## the gate is red there at the first assertion of each step. At
## 63757c8dd8 step 1 refused the profile for declaring generation 0's
## objects, and with those dropped, restarted keep-svc for its adopted
## dependency.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``. *Mocking.* None: real guests, the
## static add-on binary, manifests signed with the deploy agent's own code.

import std/[json, os, strutils, times, unittest]

import repro_deploy_agent
import repro_dsl_stdlib/packages/apt_closure
import repro_elevation/posix_system_driver
import repro_infra
import repro_addon/ledger
import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support
import ./deb_fixture_support

const Target = "addon-tb"

proc unitText(name, marker: string): string =
  ## The bytes `renderedSystemUnitContent` gives a unit with no closure and
  ## no credentials: its content, verbatim.
  "[Unit]\nDescription=" & marker & "\n\n[Service]\nExecStart=/bin/sleep " &
    "infinity\n\n[Install]\nWantedBy=multi-user.target\n"

const
  TickTimer = "repro-fx-tick.timer"
  TickService = "repro-fx-tick.service"
  TickTimerText = "[Unit]\nDescription=fixture timer\n\n[Timer]\n" &
    "OnCalendar=hourly\n\n[Install]\nWantedBy=timers.target\n"
  TickServiceText = "[Unit]\nDescription=fixture tick\n\n[Service]\n" &
    "Type=oneshot\nExecStart=/bin/true\n"
  FxGroup = "repro-fx"
  FxUser = "repro-fxu"
  FxExtra = "repro-fxextra"      ## a live member the profile does not name
  FxTool = "repro-fxtool"
  KeepConf = "/etc/repro-agent-fixture/keep.conf"
  CachesConf = "/etc/repro/caches.conf"
  Anchors = "/etc/repro/anchors/deploy-signers.anchors"

proc unitResource(name, marker: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & ".service\"\n  content = \"" &
    unitText(name, marker) & "\"\n" & extra & "}\n\n"

proc fileResource(path, content: string): string =
  "fs.systemFile {\n  path = " & quoteSystemValue(path) & "\n  content = " &
    quoteSystemValue(content) & "\n}\n\n"

proc kindMix(lockText: string): string =
  ## A timer and its service, a group and a user, an operator tool.
  "systemd.systemUnit {\n  name = \"" & TickService & "\"\n  content = " &
    quoteSystemValue(TickServiceText) & "\n  enabled = false\n}\n\n" &
  "systemd.systemTimer {\n  name = \"" & TickTimer & "\"\n  content = " &
    quoteSystemValue(TickTimerText) & "\n}\n\n" &
  "passwd.user {\n  name = \"" & FxUser & "\"\n  shell = " &
    "\"/usr/sbin/nologin\"\n}\n\n" &
  "passwd.group {\n  name = \"" & FxGroup & "\"\n  members = [\"" & FxUser &
    "\"]\n}\n\n" &
  "linux.addOnTool {\n  command = \"" & FxTool & "\"\n  aptClosureLock = " &
    quoteSystemValue(lockText) & "\n}\n\n"

proc profile(changeMarker, caches, anchors, lockText: string): string =
  ## keep-svc reads a file of the profile; caches.conf and the anchors are
  ## generation 0's objects, declared as rpi2's profile declares them.
  "addOn {\n  managedEtcPrefixes = [\"" & parentDir(KeepConf) & "/\"]\n}\n\n" &
    kindMix(lockText) &
    fileResource(KeepConf, "keep = 1\n") &
    unitResource("keep-svc", "keep",
      "  depends_on = [\"fs.systemFile:" & KeepConf & "\"]\n") &
    unitResource("change-svc", changeMarker) &
    fileResource(CachesConf, caches) & fileResource(Anchors, anchors)

proc entriesAt(g: Guest; path: string): seq[LedgerEntry] =
  for e in parseLedger(g.ledgerOf()).entries:
    if e.class == lcEtcFile and e.path == path: result.add(e)

proc accountEntry(g: Guest; key: string): LedgerEntry =
  for e in parseLedger(g.ledgerOf()).entries:
    if e.class == lcAccount and e.path == key: return e

proc timerState(g: Guest): string =
  ## When the timer last became active, and its service's last invocation:
  ## a restart of either changes them.
  g.run("systemctl show -p ActiveEnterTimestampMonotonic --value " &
        TickTimer & "; systemctl show -p InvocationID --value " &
        TickService).strip().replace("\n", " ")

proc fxToolLock(g: Guest): tuple[lock: AptClosureLock; text: string] =
  ## A one-member closure carrying /usr/bin/repro-fxtool, seeded into the
  ## add-on's deb cache so the realiser never contacts the archive.
  let deb = g.runDir / "repro-fxtool.deb"
  writeDeb(deb, @[dir("./"), dir("./usr/"), dir("./usr/bin/"),
    (name: "./usr/bin/" & FxTool, typeflag: '0', mode: 0o755,
     content: "#!/bin/sh\necho fixture tool\n", linkName: "")])
  let lock = fixtureLock(FxTool, deb)
  discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                AddOnAptDebCacheDir)
  g.copyTo(deb, AddOnAptDebCacheDir & "/" & lock.debs[0].sha256 & ".deb")
  (lock, renderAptClosureLock(lock))

proc statOf(g: Guest; path: string): string =
  g.run("stat -c '%i %y' " & path).strip()

proc unitState(g: Guest; unit: string): string =
  ## MainPID and when the unit last became active: both change on a
  ## restart, neither on a no-op.
  g.run("systemctl show -p MainPID -p ActiveEnterTimestampMonotonic " &
        "--value " & unit & ".service").strip().replace("\n", " ")

proc currentGeneration(g: Guest): string =
  extractFilename(g.run("readlink /var/lib/repro/system/current").strip())

proc agentRecordOf(g: Guest; gen: string): string =
  g.exec("cat /var/lib/repro/system/generations/" & gen & "/addon-agent").stdout

proc fakeLegacyAgent(g: Guest; text, caches: string; lock: AptClosureLock) =
  ## What rpi2's agent left behind when it applied with `repro infra apply`
  ## into its own state directory: its files and units written and running
  ## (caches.conf over generation 0's copy), and its generation, sequence
  ## floor and last tick in /var/lib/repro/agent/state.
  for (name, marker) in [("keep-svc", "keep"), ("change-svc", "v1")]:
    writeFile(g.runDir / (name & ".service"), unitText(name, marker))
    g.copyTo(g.runDir / (name & ".service"),
             "/etc/systemd/system/" & name & ".service")
  discard g.run("mkdir -p " & parentDir(KeepConf))
  writeFile(g.runDir / "keep.conf", "keep = 1\n")
  g.copyTo(g.runDir / "keep.conf", KeepConf)
  writeFile(g.runDir / "caches.conf", caches)
  g.copyTo(g.runDir / "caches.conf", CachesConf)
  discard g.run("systemctl daemon-reload && systemctl enable --now " &
                "keep-svc.service change-svc.service")
  # The timer and its service, as the legacy agent's driver left them.
  writeFile(g.runDir / TickTimer, TickTimerText)
  writeFile(g.runDir / TickService, TickServiceText)
  g.copyTo(g.runDir / TickTimer, "/etc/systemd/system/" & TickTimer)
  g.copyTo(g.runDir / TickService, "/etc/systemd/system/" & TickService)
  discard g.run("systemctl daemon-reload && systemctl enable --now " &
                TickTimer & " && systemctl start " & TickService)
  # The accounts, and a member the profile does not name (rpi2's nut group).
  discard g.run("useradd -M -s /usr/sbin/nologin " & FxUser & " && " &
                "useradd -M -s /usr/sbin/nologin " & FxExtra & " && " &
                "groupadd " & FxGroup & " && gpasswd -a " & FxUser & " " &
                FxGroup & " && gpasswd -a " & FxExtra & " " & FxGroup)
  # The tool's wrapper and launcher manifest, the bytes its driver renders,
  # and a launcher link that resolves.
  let manifest = addOnToolManifestPath(FxTool)
  writeFile(g.runDir / "fx-wrapper", renderAddOnToolWrapper(manifest))
  writeFile(g.runDir / "fx-manifest", renderAddOnToolManifest(
    aptClosurePrefixPath(AddOnSystemStoreRoot, lock), "/usr/bin/" & FxTool))
  discard g.run("mkdir -p " & AddOnToolDir)
  g.copyTo(g.runDir / "fx-wrapper", addOnToolWrapperPath(FxTool))
  g.copyTo(g.runDir / "fx-manifest", manifest)
  discard g.run("chmod 0755 " & addOnToolWrapperPath(FxTool) & " && " &
                "chmod 0644 " & manifest & " && ln -sfn /bin/true " &
                AddOnToolLauncherLink)
  let legacy = g.runDir / "legacy-state"
  removeDir(legacy)
  createDir(legacy)
  writeGenerationEnvelope(pointerPath(legacy, "legacy0001"),
    GenerationEnvelope(schemaVersion: 2, generationId: "legacy0001",
      activationTimestamp: getTime().toUnix(), hostIdentity: "addon-tb",
      profileText: text))
  let seqDir = "/var/lib/repro/agent/state/deploy-agent"
  discard g.run("mkdir -p /var/lib/repro/agent/state/generations/legacy0001 " &
                seqDir)
  g.copyTo(pointerPath(legacy, "legacy0001"),
    "/var/lib/repro/agent/state/generations/legacy0001/" &
    extractFilename(pointerPath(legacy, "legacy0001")))
  discard g.run("ln -sfn generations/legacy0001 /var/lib/repro/agent/state/current")
  discard g.run("printf '1\\n' > " & seqDir & "/" & Target & ".seq")
  discard g.run("printf '%s' '" & $(%*{"sequence": 1,
    "deploymentId": "legacy-1"}) & "' > " &
    tickStatusPath("/var/lib/repro/agent/state", Target))

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let (ok, anchors) = g.bootstrapAddonWithAnchors(repro, step)
    if not ok: return fails
    let signer = anchors.deploySignerKeys[0]
    let gen0 = g.currentGeneration()
    let caches0 = g.run("cat " & CachesConf)
    let anchorsText = g.run("cat " & Anchors)
    let caches = caches0 & "# written by the deploy agent outside the switch\n"
    let (fxLock, fxLockText) = g.fxToolLock()
    proc prof(marker: string): string =
      profile(marker, caches, anchorsText, fxLockText)
    # 1. Migration (c).
    g.fakeLegacyAgent(prof("v1"), caches, fxLock)
    let keep0 = g.unitState("keep-svc")
    let change0 = g.unitState("change-svc")
    let anchorsStat0 = g.statOf(Anchors)
    let timer0 = g.timerState()
    let wrapper = addOnToolWrapperPath(FxTool)
    let manifest = addOnToolManifestPath(FxTool)
    let tool0 = g.statOf(wrapper) & " " & g.statOf(manifest)
    # 0. The migration's plan, read-only, against copies of both state
    # directories (what the operator runs before installing the binary).
    var r = g.exec("rm -rf /var/tmp/plan-copy && mkdir -p /var/tmp/plan-copy && " &
      "cp -a /var/lib/repro/system /var/tmp/plan-copy/system && " &
      "cp -a /var/lib/repro/agent/state /var/tmp/plan-copy/agent && " &
      repro & " system addon migration-plan --target " & Target &
      " --state-dir /var/tmp/plan-copy/system --agent-state /var/tmp/plan-copy/agent")
    step("the migration plan adopts everything, restarts nothing, writes nothing",
         r.exitCode == 0 and "units stopped or restarted: 0" in r.stdout and
         "supersede\t" & CachesConf in r.stdout and
         "accepted-out-of-band\t" & CachesConf in r.stdout and
         "nothing was written" in r.stdout and g.currentGeneration() == gen0 and
         "EAddOnOutOfScope" notin r.stdout & r.stderr and
         g.statOf(Anchors) == anchorsStat0 and
         g.unitState("keep-svc") == keep0,
         r.stdout & r.stderr)
    let m1 = g.publishManifest(signer, Target, 1, prof("v1"), @[], "")
    r = g.tick(repro, Target, @[m1])
    let genMigrated = g.currentGeneration()
    let rec1 = g.agentRecordOf(genMigrated)
    step("the first tick migrates the agent into an add-on generation",
         r.exitCode == 0 and genMigrated != gen0 and
         "migrated-from\tlegacy0001" in rec1 and "sequence\t1" in rec1 and
         "deployment\tlegacy-1" in rec1, r.stdout & r.stderr & rec1)
    step("the migration restarted neither unit",
         g.unitState("keep-svc") == keep0 and g.unitState("change-svc") == change0,
         keep0 & " / " & g.unitState("keep-svc") & " ; " & change0 & " / " &
         g.unitState("change-svc"))
    var cachesEntries = g.entriesAt(CachesConf)
    step("caches.conf: the profile's bytes, one writer, superseding generation 0",
         g.run("cat " & CachesConf) == caches and cachesEntries.len == 1 and
         cachesEntries[0].collision == "supersede",
         $cachesEntries)
    step("the byte-identical anchors were taken over without a write",
         g.statOf(Anchors) == anchorsStat0 and g.entriesAt(Anchors).len == 1,
         anchorsStat0 & " / " & g.statOf(Anchors))
    # rpi2's kind mix, adopted as it is.
    step("the timer and its service were adopted, not restarted",
         g.timerState() == timer0 and
         "systemTimer:" & TickTimer in g.ledgerOf(),
         timer0 & " / " & g.timerState())
    let members = g.run("getent group " & FxGroup).strip()
    let grp = g.accountEntry("group:" & FxGroup)
    let usr = g.accountEntry("user:" & FxUser)
    step("the accounts were adopted with the undeclared member kept",
         FxExtra in members and FxUser in members and
         grp.resource == "group:" & FxGroup and usr.resource == "user:" & FxUser,
         members & " | " & $grp & " | " & $usr)
    let wrapperEntry = g.entriesAt(wrapper)
    step("the tool's wrapper and manifest were ledgered and not rewritten",
         g.statOf(wrapper) & " " & g.statOf(manifest) == tool0 and
         wrapperEntry.len == 1 and
         wrapperEntry[0].resource == "addOnTool:" & FxTool & "#wrapper" and
         g.entriesAt(manifest).len == 1,
         tool0 & " / " & g.statOf(wrapper) & " " & g.statOf(manifest) & " " &
         $wrapperEntry)
    # 2. An agent apply commits an add-on generation (a).
    let keep1 = g.unitState("keep-svc")
    let m2 = g.publishManifest(signer, Target, 2, prof("v2"), @[], "")
    r = g.tick(repro, Target, @[m2])
    let gen2 = g.currentGeneration()
    let rec2 = g.agentRecordOf(gen2)
    step("tick 2 commits an add-on generation with deployment and sequence",
         r.outcomeOf() == "aoApplied" and gen2 != genMigrated and
         "deployment\ta7-2" in rec2 and "sequence\t2" in rec2,
         r.stdout & r.stderr & rec2)
    step("the changed unit runs the new content; the other was not restarted",
         "v2" in g.run("systemctl show -p Description --value change-svc.service") and
         g.unitState("keep-svc") == keep1,
         keep1 & " / " & g.unitState("keep-svc"))
    # 3. Rollback re-applies the migrated generation and pauses (b, d).
    r = g.exec(repro & " system rollback " & genMigrated, timeoutSec = 1200)
    step("rollback to the migrated generation succeeds", r.exitCode == 0,
         r.stdout & r.stderr)
    step("after the rollback change-svc runs the old content, keep-svc untouched",
         "v1" in g.run("systemctl show -p Description --value change-svc.service") and
         g.unitState("keep-svc") == keep1, g.unitState("keep-svc"))
    let pause = g.exec("cat /var/lib/repro/agent/state/deploy-agent/pause")
    step("the rollback wrote the pause marker naming the generation",
         pause.exitCode == 0 and genMigrated in pause.stdout, pause.stdout & pause.stderr)
    let genRolled = g.currentGeneration()
    r = g.tick(repro, Target, @[m2])
    step("the next tick is paused (exit 0) and changes nothing",
         r.exitCode == 0 and r.outcomeOf() == "aoPaused" and
         g.currentGeneration() == genRolled and
         "v1" in g.run("systemctl show -p Description --value change-svc.service"),
         r.stdout & r.stderr)
    # 4. Forward again (d), then resume.
    r = g.exec(repro & " system rollback " & gen2, timeoutSec = 1200)
    step("rolling forward to generation 2 leaves keep-svc untouched",
         r.exitCode == 0 and g.unitState("keep-svc") == keep1 and
         "v2" in g.run("systemctl show -p Description --value change-svc.service"),
         r.stdout & r.stderr & g.unitState("keep-svc"))
    r = g.exec(repro & " system addon resume")
    step("resume clears the pause", r.exitCode == 0 and
         g.exec("test ! -e /var/lib/repro/agent/state/deploy-agent/pause").exitCode == 0,
         r.stdout & r.stderr)
    r = g.tick(repro, Target, @[m2])
    step("after resume the tick converges",
         r.outcomeOf() in ["aoConverged", "aoApplied"], r.stdout & r.stderr)
    # 5. Generation 0 takes its caches.conf back (b of the supersede rule).
    r = g.exec(repro & " system rollback " & gen0, timeoutSec = 1200)
    cachesEntries = g.entriesAt(CachesConf)
    step("a rollback to generation 0 restores generation 0's caches.conf",
         r.exitCode == 0 and g.run("cat " & CachesConf) == caches0 and
         cachesEntries.len == 1 and cachesEntries[0].collision == "",
         r.stdout & r.stderr & $cachesEntries)
    # The migration adopted the timer and the tool's files (they were there
    # before the add-on applied anything): leaving the profile hands them
    # back as found (§4.2), and the accounts stay (§6.4).
    let ledgerNow = g.ledgerOf()
    step("generation 0 hands the adopted timer and tool back as found, keeps the accounts",
         g.exec("test -e /etc/systemd/system/" & TickTimer & " && test -e " &
                wrapper & " && test -e " & manifest).exitCode == 0 and
         "systemTimer:" & TickTimer notin ledgerNow and
         "addOnTool:" & FxTool notin ledgerNow and
         g.exec("getent group " & FxGroup & " && getent passwd " &
                FxUser).exitCode == 0 and
         g.accountEntry("group:" & FxGroup).resource == "" and
         g.accountEntry("group:" & FxGroup).path == "group:" & FxGroup,
         ledgerNow)
  except CatchableError as e:
    fails.add(b.name & ": raised: " & e.msg)
  finally:
    record["steps"] = steps
    if g != nil: g.destroy()
  fails

suite "e2e_addon_agent_generations_and_rollback":
  test "agent applies are add-on generations; rollback reaches them and pauses the agent":
    if not gatesEnabled():
      skip("REPRO_ADDON_VM_GATES is not 1: this gate boots guests")
    else:
      var all: seq[string]
      let record = %*{"gate": "e2e_addon_agent_generations_and_rollback",
                      "reprobuild": gitHead(), "gosti": gostiHead(),
                      "bases": newJObject()}
      for b in selectedBases():
        let r = newJObject()
        all.add(runBase(b, r))
        record["bases"][b.name] = r
      discard writeRecord("e2e_addon_agent_generations_and_rollback", record)
      for f in all: echo f
      check all.len == 0

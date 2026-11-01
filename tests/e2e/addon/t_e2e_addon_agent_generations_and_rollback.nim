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
## restarted, the extra member stays, the tool's wrapper is not rewritten.
## The final rollback to generation 0 hands the adopted timer and tool
## files back as found (§4.2) and keeps both accounts (§6.4). At
## 59c075685f the switch refused the timer kind, and the plan and the
## migration both failed.
##
## rpi2 was upgraded from apt closure realiser 2 (§9 "Migration"): its
## closure units and its tools' launcher manifests bind that realiser's
## prefixes (unreceipted directories with v2's markers, laid out here by
## ``fakeV2Closure``). The migration relocates both to the store-published
## prefixes without a restart; ``repro store recover`` and ``repro store
## gc`` then keep the older prefixes, which the running service and the
## preserved bytes still name; and after the rollback to generation 0 the
## handed-back unit restarts from its older prefix. At 7d7313432b the plan
## refused the manifest as EDrift, and the older prefixes were held by
## nothing. The plan also names every refusal at once (a plan over two
## hand-written files names both; at 7d7313432b, the first only). Before
## the migration, too, `store recover` and `store gc` keep what the units
## and manifest on disk bind (at 0e84765db0 they adopted and collected it).
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

import std/[json, os, osproc, strutils, times, unittest]

import repro_deploy_agent
import repro_dsl_stdlib/packages/apt_closure
from repro_dsl_stdlib/packages/apt_jammy import sha256OfString
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
  LegacySecrets = "/var/lib/repro/agent/secrets"
    ## rpi2's full-engine agent's --secrets-dir (§10.3, "Legacy delivery")
  CredSecret = LegacySecrets & "/secrets/repro-fx-cred/token"
  CredServiceText = "[Unit]\nDescription=legacy credential\n\n[Service]\n" &
    "ExecStart=/bin/sleep infinity\nLoadCredential=token:" & CredSecret &
    "\n\n[Install]\nWantedBy=multi-user.target\n"
  CachesConf = "/etc/repro/caches.conf"
  Anchors = "/etc/repro/anchors/deploy-signers.anchors"

proc unitResource(name, marker: string; extra = ""): string =
  "systemd.systemUnit {\n  name = \"" & name & ".service\"\n  content = \"" &
    unitText(name, marker) & "\"\n" & extra & "}\n\n"

proc fileResource(path, content: string): string =
  "fs.systemFile {\n  path = " & quoteSystemValue(path) & "\n  content = " &
    quoteSystemValue(content) & "\n}\n\n"

const
  FxClosureUnit = "repro-fx-closure.service"
  FxClosureText = "[Unit]\nDescription=closure fixture\n\n[Service]\n" &
    "ExecStart=/usr/bin/busybox sleep infinity\n\n[Install]\n" &
    "WantedBy=multi-user.target\n"

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
    quoteSystemValue(lockText) & "\n}\n\n" &
  "systemd.systemUnit {\n  name = \"repro-fx-cred.service\"\n  content = " &
    quoteSystemValue(CredServiceText) & "\n}\n\n"

proc profile(changeMarker, caches, anchors, lockText: string;
             extra = ""; addOnExtra = ""; closureLockText = ""): string =
  ## keep-svc reads a file of the profile; caches.conf and the anchors are
  ## generation 0's objects, declared as rpi2's profile declares them.
  "addOn {\n  managedEtcPrefixes = [\"" & parentDir(KeepConf) & "/\"]\n" &
    addOnExtra & "}\n\n" &
    kindMix(lockText) & extra &
    (if closureLockText.len > 0:
       "systemd.systemUnit {\n  name = \"" & FxClosureUnit & "\"\n  content = " &
       quoteSystemValue(FxClosureText) & "\n  aptClosureLock = " &
       quoteSystemValue(closureLockText) & "\n}\n\n"
     else: "") &
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

proc staticBusybox(): string =
  ## A static busybox (this flake's nixpkgs), so the closure fixture's
  ## service runs from the closure's own /usr.
  let (o, rc) = execCmdEx("nix build --no-link --print-out-paths " &
    "--inputs-from " & quoteShell(reproRoot()) & " nixpkgs#pkgsStatic.busybox")
  if rc != 0: raise newException(IOError, "nix build of a static busybox: " & o)
  o.strip().splitLines()[^1] / "bin" / "busybox"

proc fxClosureLock(g: Guest): tuple[lock: AptClosureLock; text: string] =
  ## A one-member closure whose /usr carries a static busybox: the package a
  ## unit runs from, as rpi2's prometheus-node-exporter runs from its own.
  let deb = g.runDir / "repro-fxsvc.deb"
  writeDeb(deb, @[dir("./"), dir("./usr/"), dir("./usr/bin/"),
    (name: "./usr/bin/busybox", typeflag: '0', mode: 0o755,
     content: readFile(staticBusybox()), linkName: "")])
  let lock = fixtureLock("repro-fxsvc", deb)
  discard g.run("mkdir -p " & AddOnAptDebCacheDir & " && chmod 0700 " &
                AddOnAptDebCacheDir)
  g.copyTo(deb, AddOnAptDebCacheDir & "/" & lock.debs[0].sha256 & ".deb")
  (lock, renderAptClosureLock(lock))

proc closureUnit(lockText: string): SystemResource =
  SystemResource(kind: srkSystemdSystemUnit, address: "systemUnit:" &
    FxClosureUnit, suName: FxClosureUnit, suContent: FxClosureText,
    suEnabled: true, suAptClosureLock: lockText)

proc v2MemberPath(d: AptLockedDeb): string =
  ## Realiser v2's member prefix, from that realiser's formula (written out
  ## here, independently of the adoption code under test).
  AddOnSystemStoreRoot / "prefixes" / ("apt-deb-" & d.name) /
    (d.version.replace(':', '_') & "-" &
     sha256OfString("repro.apt-deb\x00" & "2" & "\x00" & d.sha256)[0 ..< 16])

proc fakeV2Closure(g: Guest; lock: AptClosureLock; local, program: string) =
  ## A one-member closure as realiser v2 published it (rpi2's 13
  ## apt-closure-* and 185 apt-deb-* prefixes): the member and the union,
  ## each carrying ``program`` (the guest's file ``local``) and v2's marker,
  ## no store receipt, no index row. The paths and the identity come from
  ## the lock; the marker format is v2's.
  let union = legacyAptClosurePrefixPaths(AddOnSystemStoreRoot, lock)[0]
  let d = lock.debs[0]
  let member = v2MemberPath(d)
  let identity = union.extractFilename.rsplit('-', 1)[1]
  var cmds: seq[string]
  for (dir, marker, text) in [
      (member, ".repro-apt-deb", d.sha256 & "\n"),
      (union, ".repro-apt-closure",
       "identity " & identity & "\n" & d.name & " " & d.sha256 & "\n")]:
    cmds.add("mkdir -p " & dir & parentDir(program) & " && cp " & local &
      " " & dir & program & " && chmod 0755 " & dir & program &
      " && printf \"" & text.replace("\n", "\\n") & "\" > " & dir & "/" &
      marker & " && chmod 0644 " & dir & "/" & marker)
  # /repro/store is bound read-only; the older realiser wrote below it, so
  # the fixture writes in a private mount namespace without the bind, as
  # the switch's own writable view does.
  discard g.run("unshare -m sh -c 'umount /repro/store && " &
    cmds.join(" && ") & "'")

proc fakeLegacyClosureUnit(g: Guest; lock: AptClosureLock; lockText: string) =
  ## What an agent of an older closure realiser left: the unit bound to that
  ## realiser's prefix of the same closure (``fakeV2Closure``), its service
  ## running from it. rpi2's 22 closure units.
  g.copyTo(staticBusybox(), "/var/tmp/repro-fx-busybox")
  g.fakeV2Closure(lock, "/var/tmp/repro-fx-busybox", "/usr/bin/busybox")
  writeFile(g.runDir / FxClosureUnit,
            legacyClosureRenderings(closureUnit(lockText))[0])
  g.copyTo(g.runDir / FxClosureUnit, "/etc/systemd/system/" & FxClosureUnit)
  discard g.run("systemctl daemon-reload && systemctl enable --now " &
                FxClosureUnit)

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
  # A unit loading a secret from the legacy --secrets-dir by hand.
  discard g.run("mkdir -p " & parentDir(CredSecret) & " && printf secret > " &
                CredSecret & " && chmod 0600 " & CredSecret)
  writeFile(g.runDir / "repro-fx-cred.service", CredServiceText)
  g.copyTo(g.runDir / "repro-fx-cred.service",
           "/etc/systemd/system/repro-fx-cred.service")
  # The timer and its service, as the legacy agent's driver left them.
  writeFile(g.runDir / TickTimer, TickTimerText)
  writeFile(g.runDir / TickService, TickServiceText)
  g.copyTo(g.runDir / TickTimer, "/etc/systemd/system/" & TickTimer)
  g.copyTo(g.runDir / TickService, "/etc/systemd/system/" & TickService)
  discard g.run("systemctl daemon-reload && systemctl enable --now " &
                TickTimer & " repro-fx-cred.service && systemctl start " &
                TickService)
  # The full-engine agent registers its --secrets-dir with the add-on on
  # its first tick (``registerLegacySecretsDir``); the static agent the gate
  # drives has none, so the registration is made here, as that agent would.
  discard g.run("mkdir -p /var/lib/repro/system/addon && printf '%s\\n' " &
                LegacySecrets & " > /var/lib/repro/system/addon/" &
                "legacy-secrets-dirs")
  # The accounts, and a member the profile does not name (rpi2's nut group).
  discard g.run("useradd -M -s /usr/sbin/nologin " & FxUser & " && " &
                "useradd -M -s /usr/sbin/nologin " & FxExtra & " && " &
                "groupadd " & FxGroup & " && gpasswd -a " & FxUser & " " &
                FxGroup & " && gpasswd -a " & FxExtra & " " & FxGroup)
  # The tool's wrapper and launcher manifest, the bytes the older
  # realiser's driver rendered -- the manifest names that realiser's prefix
  # of the tool's closure, as rpi2's ipmitool and wakeonlan manifests do --
  # and a launcher link that resolves.
  let manifest = addOnToolManifestPath(FxTool)
  writeFile(g.runDir / "fx-tool", "#!/bin/sh\necho fixture tool\n")
  g.copyTo(g.runDir / "fx-tool", "/var/tmp/repro-fx-tool")
  g.fakeV2Closure(lock, "/var/tmp/repro-fx-tool", "/usr/bin/" & FxTool)
  writeFile(g.runDir / "fx-wrapper", renderAddOnToolWrapper(manifest))
  writeFile(g.runDir / "fx-manifest", renderAddOnToolManifest(
    legacyAptClosurePrefixPaths(AddOnSystemStoreRoot, lock)[0],
    "/usr/bin/" & FxTool))
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
    let (fxSvcLock, fxSvcLockText) = g.fxClosureLock()
    proc prof(marker: string; extra = ""; addOnExtra = "";
              cachesText = caches): string =
      profile(marker, cachesText, anchorsText, fxLockText, extra, addOnExtra,
              fxSvcLockText)
    # 1. Migration (c).
    g.fakeLegacyAgent(prof("v1"), caches, fxLock)
    g.fakeLegacyClosureUnit(fxSvcLock, fxSvcLockText)
    var closure0 = g.unitState("repro-fx-closure")
    let legacyClosureBytes = g.run("cat /etc/systemd/system/" & FxClosureUnit)
    let keep0 = g.unitState("keep-svc")
    let change0 = g.unitState("change-svc")
    let anchorsStat0 = g.statOf(Anchors)
    let timer0 = g.timerState()
    let cred0 = g.unitState("repro-fx-cred")
    let wrapper = addOnToolWrapperPath(FxTool)
    let manifest = addOnToolManifestPath(FxTool)
    let wrapperBytes = g.run("cat " & wrapper)
    let legacyManifestBytes = g.run("cat " & manifest)
    let svcLegacy = legacyAptClosurePrefixPaths(AddOnSystemStoreRoot,
                                                fxSvcLock)[0]
    let toolLegacy = legacyAptClosurePrefixPaths(AddOnSystemStoreRoot,
                                                 fxLock)[0]
    # Before any migration (rpi2 today): the older realiser's prefixes are
    # bound only by the units and the manifest on disk. A `store recover`
    # or `store gc` from the new binary adopts them, and must hold them, not
    # collect them under the running service. At 0e84765db0 nothing held
    # them before the first switch.
    block:
      let rc0 = g.exec(repro & " store recover")
      let gc0 = g.exec(repro & " store gc --grace-seconds 0")
      step("before the migration, store recover and gc keep what the units and manifests bind",
           rc0.exitCode == 0 and gc0.exitCode == 0 and
           g.exec("test -x " & svcLegacy & "/usr/bin/busybox && test -x " &
                  toolLegacy & "/usr/bin/" & FxTool & " && test -d " &
                  v2MemberPath(fxSvcLock.debs[0]) & " && test -d " &
                  v2MemberPath(fxLock.debs[0])).exitCode == 0 and
           g.unitState("repro-fx-closure") == closure0 and
           g.exec("systemctl restart " & FxClosureUnit & " && sleep 1 && " &
                  "systemctl is-active " & FxClosureUnit).exitCode == 0,
           rc0.stdout & rc0.stderr & gc0.stdout & gc0.stderr)
      # The restart above started a new instance: the migration's
      # no-restart checks compare against it.
      closure0 = g.unitState("repro-fx-closure")
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
         "relocate-closure\t/etc/systemd/system/" & FxClosureUnit in r.stdout and
         "relocate-closure\t" & manifest in r.stdout and
         "store space: 2 closure(s) to realise" in r.stdout and
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
    let manifestEntry = g.entriesAt(manifest)
    # rpi2's ipmitool and wakeonlan (§9 "Migration"): the wrapper names no
    # prefix and was adopted as it is; the manifest bound the older
    # realiser's prefix and was relocated. At 7d7313432b the plan and the
    # migration refused the manifest as EDrift.
    step("the tool's wrapper was adopted, its manifest relocated to the store prefix",
         g.run("cat " & wrapper) == wrapperBytes and
         wrapperEntry.len == 1 and
         wrapperEntry[0].resource == "addOnTool:" & FxTool & "#wrapper" and
         g.run("cat " & manifest) == renderAddOnToolManifest(
           aptClosurePrefixPath(AddOnSystemStoreRoot, fxLock),
           "/usr/bin/" & FxTool) and
         manifestEntry.len == 1 and
         manifestEntry[0].collision == "closure-relocate",
         $wrapperEntry & " " & $manifestEntry & "\n" &
         g.run("cat " & manifest))
    # rpi2's closure units (§9 "Migration"): bound to an older realiser's
    # prefix, rewritten at the store-published one, not restarted. At
    # 4379adfd3b the plan and the migration refused it as EDrift.
    let closureEntries = block:
      var es: seq[LedgerEntry]
      for e in parseLedger(g.ledgerOf()).entries:
        if e.class == lcUnit and e.unit == FxClosureUnit: es.add(e)
      es
    step("the closure unit is relocated to the store-published prefix, not restarted",
         g.unitState("repro-fx-closure") == closure0 and
         aptClosurePrefixPath(AddOnSystemStoreRoot, fxSvcLock) in
           g.run("cat /etc/systemd/system/" & FxClosureUnit) and
         closureEntries.len == 1 and
         closureEntries[0].collision == "closure-relocate",
         closure0 & " / " & g.unitState("repro-fx-closure") & " " &
         $closureEntries)
    # The relocated service still runs from the older prefix, and a
    # rollback writes the older bytes back: the store's recovery (which
    # quarantines a prefix without a receipt) and its collector (which
    # takes what no root holds) must leave both older prefixes, and their
    # members, in place. At 7d7313432b nothing held them.
    let rc = g.exec(repro & " store recover")
    let gcr = g.exec(repro & " store gc --grace-seconds 0")
    step("store recover and gc keep the prefixes the relocated objects came from",
         rc.exitCode == 0 and gcr.exitCode == 0 and
         g.exec("test -x " & svcLegacy & "/usr/bin/busybox && test -x " &
                toolLegacy & "/usr/bin/" & FxTool & " && test -d " &
                v2MemberPath(fxSvcLock.debs[0]) &
                " && test -d " &
                v2MemberPath(fxLock.debs[0])).
           exitCode == 0 and
         g.unitState("repro-fx-closure") == closure0 and
         "addon-hand-back" in g.run(repro & " store roots"),
         rc.stdout & rc.stderr & gcr.stdout & gcr.stderr)
    # Every refusal in one report (rpi2's migration plan stopped at one
    # refusal per run): two hand-written files the profile would take over
    # with other bytes. At 7d7313432b only the first was named.
    let driftA = parentDir(KeepConf) / "drift-a.conf"
    let driftB = parentDir(KeepConf) / "drift-b.conf"
    discard g.run("printf 'hand a\\n' > " & driftA & " && printf 'hand b\\n' > " &
                  driftB)
    r = g.planProfile(repro, "drift", prof("v1",
      extra = fileResource(driftA, "a = 1\n") & fileResource(driftB, "b = 1\n")))
    step("a plan names every refusal, not only the first",
         r.exitCode == 2 and ("EDrift: " & driftA) in r.stdout & r.stderr and
         ("EDrift: " & driftB) in r.stdout & r.stderr and
         "1 more refusal:" in r.stdout & r.stderr and
         g.run("cat " & driftA) == "hand a\n",
         r.stdout & r.stderr)
    discard g.run("rm -f " & driftA & " " & driftB)
    step("the legacy LoadCredential= unit was adopted, not restarted",
         "systemUnit:repro-fx-cred.service" in g.ledgerOf() and
         g.unitState("repro-fx-cred") == cred0, cred0 & " / " &
         g.unitState("repro-fx-cred"))
    # A LoadCredential= from anywhere else is refused, with nothing written
    # (§10.3): an operator plan of the same profile plus one such unit.
    writeFile(g.runDir / "outside.profile", prof("v1",
      extra = "systemd.systemUnit {\n  name = \"repro-fx-outside.service\"\n" &
        "  content = " & quoteSystemValue("[Service]\nExecStart=/bin/true\n" &
        "LoadCredential=token:/etc/repro-agent-fixture/token\n") & "\n}\n\n"))
    g.copyTo(g.runDir / "outside.profile", "/var/tmp/outside.profile")
    r = g.exec(repro & " infra plan --profile /var/tmp/outside.profile")
    step("a LoadCredential= outside the agent's --secrets-dir is refused",
         r.exitCode == 2 and "LoadCredential" in r.stderr & r.stdout and
         "repro-fx-outside" in r.stderr & r.stdout,
         r.stdout & r.stderr)
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
    # 4b. An agent switch that fails after its flip, over a caches.conf
    # changed by hand to the bytes manifest 3 declares (accepted without a
    # write): manifest 3 adds a unit whose health check fails, and the
    # switch is reverted automatically, with no pending marker left. (The
    # case where the failed switch had not yet written its ledger, the one
    # that refused at f25f69eda0, is e2e_addon_revert_keeps_earlier_drift.)
    let genBefore3 = g.currentGeneration()
    let caches3 = caches & "# changed by hand before manifest 3\n"
    writeFile(g.runDir / "caches3", caches3)
    g.copyTo(g.runDir / "caches3", CachesConf)
    let m3 = g.publishManifest(signer, Target, 3, prof("v2",
      extra = "systemd.systemUnit {\n  name = \"repro-fx-fail.service\"\n" &
        "  content = " & quoteSystemValue(unitText("repro-fx-fail", "fail")) &
        "\n  healthCheck = \"tcp:127.0.0.1:9\"\n}\n\n",
      addOnExtra = "  confirmTimeout = 15\n", cachesText = caches3), @[], "")
    r = g.tick(repro, Target, @[m3])
    step("a switch that fails after its flip is reverted over earlier drift",
         r.outcomeOf() == "aoRolledBack" and
         ("rolled back to " & genBefore3) in r.stdout & r.stderr and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0 and
         g.exec("systemctl is-active repro-fx-fail.service").stdout.strip() !=
           "active",
         r.stdout & r.stderr & "\ncaches.conf now:\n" &
         g.exec("cat " & CachesConf).stdout & "\npending:\n" &
         g.exec("cat /var/lib/repro/system/addon/pending").stdout)
    # The revert re-applied generation 2's caches.conf; put back explicitly,
    # whatever it did, so the rollback below starts from the ledger's bytes.
    writeFile(g.runDir / "caches2", caches)
    g.copyTo(g.runDir / "caches2", CachesConf)
    # 5. Generation 0 takes its caches.conf back (b of the supersede rule).
    # Every unit handed back was adopted, with the bytes it has: none is
    # restarted (keep-svc stands for rpi2's Alertmanager).
    let keepBefore0 = g.unitState("keep-svc")
    r = g.exec(repro & " system rollback " & gen0, timeoutSec = 1200)
    step("a rollback to generation 0 restarts no handed-back unit",
         r.exitCode == 0 and g.unitState("keep-svc") == keepBefore0 and
         g.unitState("repro-fx-cred") == cred0 and
         g.unitState("repro-fx-closure") == closure0 and
         g.run("cat /etc/systemd/system/" & FxClosureUnit) == legacyClosureBytes,
         keepBefore0 & " / " & g.unitState("keep-svc") & " ; " & cred0 &
         " / " & g.unitState("repro-fx-cred"))
    # Generation 0's unit binds the older prefix again: it must still be
    # there when the service next starts (the outage §9 rules out).
    discard g.exec(repro & " store gc --grace-seconds 0")
    r = g.exec("systemctl restart " & FxClosureUnit & " && sleep 1 && " &
               "systemctl is-active " & FxClosureUnit)
    step("after the rollback the handed-back closure unit restarts from the older prefix",
         r.exitCode == 0 and r.stdout.strip() == "active" and
         g.run("cat " & manifest) == legacyManifestBytes,
         r.stdout & r.stderr & g.exec("journalctl -u " & FxClosureUnit &
                                      " -n 20 --no-pager").stdout)
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

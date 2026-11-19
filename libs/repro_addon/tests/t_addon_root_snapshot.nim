## Unit tests for the switch's own root snapshot (spec ReproOS-Add-On-Mode
## §7.2, §6.4, §8.5; §13 decisions 90, 100, 101, 105, 116, 119;
## ``repro_addon/root_snapshot``): the ``rootSnapshot`` setting through the
## text form, the intent and the profile intent, the plan's decision, the
## record written before ``snapper create``, deletion by key and never by
## number alone, the orphan sweep's owners (a present marker, a retained
## committed generation), its two narrowings (keys this state recorded; a
## store whose roots cannot be listed keeps every generation's snapshot),
## the snapshot ``/`` runs from, retention, uninstall, and the pending
## marker's new fields.
##
## *Mocking.* snapper's configurations and snapshots are real files in a
## fixture tree under a temporary root, laid out as snapper lays them out
## (snapper-configs(5): ``/etc/snapper/configs/<name>`` with ``SUBVOLUME``;
## ``<SUBVOLUME>/.snapshots/<n>/info.xml``, written as snapper 0.13.2 writes
## it on the Omarchy test bed). One substitution, because the build host
## has neither snapper nor a btrfs root to snapshot: the ``SnapperRunner``
## is a closure that creates and deletes those directories, numbering as
## snapper does (the highest existing number plus one), and can be told to
## fail. ``/proc/self/mountinfo`` is passed as text. The store's generation
## roots are passed to the sweep as a list (the build host has no add-on
## store). The live half -- snapper over D-Bus, snapperd, a real btrfs
## snapshot, booting one -- runs in the Omarchy VM gates
## (``e2e_arch_addon_root_snapshot_setting``,
## ``e2e_omarchy_addon_root_snapshot_rollback``).

import std/[os, sets, strutils, unittest]

import repro_infra/addon_diagnostics
import repro_infra/errors
import repro_infra/intent
import repro_infra/profile
import repro_profile/types as profileTypes
import repro_profile/emit as profileEmit
import repro_profile_intent/codec
import repro_addon/[generation0, preflight, reassert, root_snapshot, static_tree]
import repro_core/host_apply_lock

let base = getTempDir() / ("repro-addon-root-snapshot-" & $getCurrentProcessId())

type Fake = ref object
  root: string
  calls: seq[seq[string]]
  failCreate, failDelete: bool
  recordSeenAtCreate: bool
  stateDir: string

proc put(root, rel, content: string) =
  createDir(parentDir(root / rel))
  writeFile(root / rel, content)

proc infoXml(n: int; desc: string; key = ""; value = ""): string =
  result = "<?xml version=\"1.0\"?>\n<snapshot>\n  <type>single</type>\n  <num>" &
    $n & "</num>\n  <date>2026-11-16 21:59:25</date>\n  <description>" & desc &
    "</description>\n"
  if key.len > 0:
    result.add("  <userdata>\n    <key>" & key & "</key>\n    <value>" & value &
               "</value>\n  </userdata>\n")
  result.add("</snapshot>\n")

proc snapDir(f: Fake; n: int): string = f.root / ".snapshots" / $n

proc highest(f: Fake): int =
  if not dirExists(f.root / ".snapshots"): return 0
  for kind, d in walkDir(f.root / ".snapshots"):
    try: result = max(result, parseInt(extractFilename(d)))
    except ValueError: discard

proc omarchySnapshot(f: Fake): int =
  ## A snapshot Omarchy takes (`snapper create -c number`): no userdata.
  result = f.highest + 1
  put(f.root, ".snapshots/" & $result & "/info.xml", infoXml(result, "4.5.0-3"))
  createDir(f.snapDir(result) / "snapshot")

proc runner(f: Fake): SnapperRunner =
  result = proc (args: seq[string]): tuple[exitCode: int; output: string] =
    f.calls.add(args)
    if "create" in args:
      if f.stateDir.len > 0:
        f.recordSeenAtCreate = readRecords(f.stateDir).len > 0
      if f.failCreate: return (1, "Failure (error.something).")
      let n = f.highest + 1
      var ud = ""
      let i = args.find("--userdata")
      if i >= 0: ud = args[i + 1]
      let kv = ud.split('=', 1)
      put(f.root, ".snapshots/" & $n & "/info.xml",
          infoXml(n, "x", kv[0], (if kv.len > 1: kv[1] else: "")))
      createDir(f.snapDir(n) / "snapshot")
      return (0, $n & "\n")
    if "delete" in args:
      if f.failDelete: return (1, "Deleting snapshot failed.")
      # `-c <config>`: the fixture's only other configuration is /home.
      let sub = if args[1] == "home": f.root / "home" else: f.root
      removeDir(sub / ".snapshots" / args[^1])
      return (0, "")
    (2, "unexpected")

proc newSite(name: string; withConfig = true; configName = "root"):
    tuple[f: Fake; site: SnapshotSite; state: string] =
  let root = base / name
  removeDir(root)
  createDir(root)
  if withConfig:
    put(root, "etc/snapper/configs/" & configName,
        "SUBVOLUME=\"/\"\nFSTYPE=\"btrfs\"\nNUMBER_LIMIT=\"5\"\n")
  let f = Fake(root: root, stateDir: root / "state")
  createDir(f.stateDir)
  (f, SnapshotSite(root: root, snapper: runner(f),
                   mountinfo: "29 1 0:24 /@ / rw,relatime shared:1 - btrfs " &
                              "/dev/vda2 rw,subvol=/@\n",
                   cmdline: "root=PARTUUID=x rootflags=subvol=@ rw\n"), f.stateDir)

proc keysOnHost(site: SnapshotSite): seq[string] =
  for s in addonSnapshotsOnHost(site): result.add(s.key)

proc takeOne(state: string; site: SnapshotSite): RootSnapshotRecord =
  let p = planRootSnapshot(rsIfConfigured, true, site)
  let t = takeRootSnapshot(state, p, "repro-addon gen test", site)
  doAssert t.ok, t.why
  t.record

proc writeMarker(state, key: string) =
  writePendingMarker(state, PendingMarker(fromGeneration: "g1",
    step: ssRealise, status: "in-progress", purpose: "apply",
    rootSnapshot: key))

suite "the rootSnapshot setting":
  test "text form: the three values, quoted; the default is ifConfigured":
    check parseAddOnStanza("managedEtcPrefixes = []").rootSnapshot == rsIfConfigured
    check not parseAddOnStanza("managedEtcPrefixes = []").rootSnapshotDeclared
    for v in ["required", "ifConfigured", "off"]:
      let s = parseAddOnStanza("rootSnapshot = \"" & v & "\"")
      check $s.rootSnapshot == v
      check s.rootSnapshotDeclared
  test "text form: an unknown value, an unquoted one and a second one are refused":
    for bad in ["rootSnapshot = \"always\"", "rootSnapshot = required",
                "rootSnapshot = \"off\"\nrootSnapshot = \"off\""]:
      expect ESystemProfileInvalid:
        discard parseAddOnStanza(bad)
  test "the rendered stanza carries it only when declared, and reads back":
    var s = parseAddOnStanza("managedEtcPrefixes = []")
    check "rootSnapshot" notin renderAddOnStanza(s).join("\n")
    s = parseAddOnStanza("managedEtcPrefixes = []\nrootSnapshot = \"required\"")
    let text = renderAddOnStanza(s).join("\n")
    check "rootSnapshot = \"required\"" in text
    let body = text[text.find('{') + 1 ..< text.rfind('}')]
    check parseAddOnStanza(body).rootSnapshot == rsRequired
  test "the profile intent's JSON and CBOR carry it, and refuse a bad one":
    var p = ProfileIntent()
    p.addOn.declared = true
    p.addOn.rootSnapshot = "off"
    let back = parseProfileIntentJson(emitProfileIntentJson(p))
    check back.addOn.rootSnapshot == "off"
    let none = ProfileIntent(addOn: AddOnIntent(declared: true))
    check "rootSnapshot" notin emitProfileIntentJson(none)
    let bad = emitProfileIntentJson(p).replace("\"rootSnapshot\":\"off\"",
                                               "\"rootSnapshot\":\"never\"")
    expect ValueError:
      discard parseProfileIntentJson(bad)
    check decodeRbpi(encodeRbpi(p)).addOn.rootSnapshot == "off"
    check decodeRbpi(encodeRbpi(none)).addOn.rootSnapshot == ""

suite "snapper's files":
  test "the repro-addon userdata value, as snapper 0.13.2 writes info.xml":
    check snapperUserdataValue(infoXml(1, "d", "repro-addon", "abc123")) ==
      (true, "abc123")
    check snapperUserdataValue(infoXml(1, "d", "important", "yes")) == (false, "")
    check snapperUserdataValue(infoXml(1, "d")) == (false, "")
    check snapperUserdataValue("<snapshot><userdata><key>important</key>" &
      "<value>y</value></userdata><userdata>\n <key>repro-addon</key>\n" &
      " <value>k2</value>\n</userdata></snapshot>") == (true, "k2")
  test "the configuration for /: root preferred, else the first; none for another subvolume":
    var (f, site, _) = newSite("configs")
    check rootSnapshotConfig(site) == "root"
    put(f.root, "etc/snapper/configs/aaa", "SUBVOLUME=\"/\"\n")
    check rootSnapshotConfig(site) == "root"
    removeFile(f.root / "etc/snapper/configs/root")
    check rootSnapshotConfig(site) == "aaa"
    removeFile(f.root / "etc/snapper/configs/aaa")
    put(f.root, "etc/snapper/configs/home", "SUBVOLUME=\"/home\"\n")
    check rootSnapshotConfig(site) == ""
  test "the subvolume / is mounted from, plain, a snapshot and an overlay":
    check rootMountSource("29 1 0:24 /@ / rw,relatime shared:1 - btrfs " &
      "/dev/vda2 rw,subvol=/@\n") == "/@"
    check rootMountSource("29 1 0:24 /@/.snapshots/7/snapshot / ro shared:1 - " &
      "btrfs /dev/vda2 ro,subvol=/@/.snapshots/7/snapshot\n") ==
      "/@/.snapshots/7/snapshot"
    check rootMountSource("30 1 0:40 / / rw shared:1 - overlay overlay " &
      "rw,lowerdir=/run/rootfs/@/.snapshots/7/snapshot,upperdir=/run/u,workdir=/run/w\n") ==
      "/run/rootfs/@/.snapshots/7/snapshot"
    check rootMountSource("31 29 0:25 / /home rw - btrfs /dev/vda2 rw\n") == ""

suite "the plan's decision (spec §7.2, §8.5)":
  test "required, ifConfigured and off with a configuration for /":
    let (_, site, _) = newSite("plan-with")
    for s in [rsRequired, rsIfConfigured]:
      let p = planRootSnapshot(s, true, site)
      check p.take and p.config == "root" and p.refusal == ""
      check "snapper configuration root" in p.line
    let off = planRootSnapshot(rsOff, true, site)
    check not off.take and "no second way back exists" in off.line
  test "without one: required is refused, ifConfigured says there is no second way back":
    let (_, site, _) = newSite("plan-without", withConfig = false)
    let r = planRootSnapshot(rsRequired, true, site)
    check not r.take and "no configuration for /" in r.refusal
    check $adRootSnapshot in r.line
    let i = planRootSnapshot(rsIfConfigured, true, site)
    check not i.take and i.refusal == "" and "no second way back exists" in i.line
  test "a rollback, a revert, a replay and generation 0 take none, whatever the setting":
    let (_, site, _) = newSite("plan-not-fresh")
    for s in [rsRequired, rsIfConfigured, rsOff]:
      let p = planRootSnapshot(s, false, site)
      check not p.take and p.refusal == ""

suite "taking the snapshot":
  test "the record is on disk before snapper create; the call is the spec's":
    var (f, site, state) = newSite("take")
    let rec = takeOne(state, site)
    check f.recordSeenAtCreate
    check isSnapshotKey(rec.key) and rec.number == 1 and rec.config == "root"
    let c = f.calls[^1]
    check c[0 .. 2] == @["-c", "root", "create"]
    let i = c.find("--cleanup-algorithm")
    check i >= 0 and c[i + 1] == ""
    check "--print-number" in c
    check c[c.find("--userdata") + 1] == "repro-addon=" & rec.key
    check readRecords(state) == @[rec]
    check keysOnHost(site) == @[rec.key]
  test "two attempts draw different keys":
    let (_, site, state) = newSite("take-two")
    check takeOne(state, site).key != takeOne(state, site).key
  test "a failed create leaves no record and says why":
    var (f, site, state) = newSite("take-fail")
    f.failCreate = true
    let t = takeRootSnapshot(state, planRootSnapshot(rsRequired, true, site),
                             "d", site)
    check not t.ok and "create failed" in t.why and "error.something" in t.why
    check readRecords(state).len == 0

suite "deleting by key, never by number alone (threat model T61)":
  test "only the snapshot carrying the key, and then its record":
    var (f, site, state) = newSite("delete")
    let a = takeOne(state, site)
    let o = f.omarchySnapshot()
    let b = takeOne(state, site)
    let d = deleteSnapshotByKey(state, a.key, "the test", site)
    check d.left.len == 0 and d.deleted.len == 1
    check keysOnHost(site) == @[b.key]
    check dirExists(f.snapDir(o))
    var keys: seq[string]
    for r in readRecords(state): keys.add(r.key)
    check keys == @[b.key]
  test "a number reused by Omarchy after the add-on's snapshot went is never deleted":
    var (f, site, state) = newSite("reuse")
    let a = takeOne(state, site)
    check deleteSnapshotByKey(state, a.key, "t", site).left.len == 0
    let o = f.omarchySnapshot()
    check o == a.number          # snapper numbers from the highest left
    check deleteSnapshotByKey(state, a.key, "t", site).deleted.len == 0
    check dirExists(f.snapDir(o))
  test "a failed delete is EAddOnSnapshotLeft, and the record stays for the sweep":
    var (f, site, state) = newSite("delete-fail")
    let a = takeOne(state, site)
    f.failDelete = true
    let d = deleteSnapshotByKey(state, a.key, "the revert", site)
    check d.left.len == 1 and d.left[0].startsWith($adSnapshotLeft)
    check "the revert" in d.left[0] and "root#" & $a.number in d.left[0]
    check readRecords(state).len == 1
  test "the snapshot / runs from is never deleted":
    var (f, site, state) = newSite("running")
    let a = takeOne(state, site)
    var s2 = site
    s2.mountinfo = "29 1 0:24 /@/.snapshots/" & $a.number & "/snapshot / ro - " &
      "btrfs /dev/vda2 ro\n"
    let d = deleteSnapshotByKey(state, a.key, "t", s2)
    check d.deleted.len == 0 and d.left.len == 1
    check "booted into this snapshot" in d.left[0]
    check dirExists(f.snapDir(a.number))

suite "the orphan sweep (spec §7.2, §13 decision 116)":
  setup:
    var (f, site, state) = newSite("sweep")
  test "an unowned recorded snapshot is deleted; Omarchy's are not":
    let a = takeOne(state, site)
    let o = f.omarchySnapshot()
    let lines = sweepOrphanSnapshots(state, "", "", [state], site, (true, @[]))
    check lines.len == 1 and "deleted the orphan" in lines[0]
    check keysOnHost(site).len == 0 and dirExists(f.snapDir(o))
    check readRecords(state).len == 0
    discard a
  test "a present marker's attempt owns its snapshot":
    let a = takeOne(state, site)
    writeMarker(state, a.key)
    check sweepOrphanSnapshots(state, "", "", [state], site, (true, @[])).len == 0
    check keysOnHost(site) == @[a.key]
    clearPendingMarker(state)
    discard sweepOrphanSnapshots(state, "", "", [state], site, (true, @[]))
    check keysOnHost(site).len == 0
  test "a pending revert's marker owns the snapshot of the attempt it reverts":
    # The failed attempt's snapshot is its way back while its revert has
    # not completed (§13 decision 105): the revert's marker names it only
    # as ``revert-snapshot``.
    let failed = takeOne(state, site)
    writePendingMarker(state, PendingMarker(fromGeneration: "g2",
      step: ssRealise, status: "in-progress", purpose: "revert",
      revertOf: "g3", revertSnapshot: failed.key))
    check sweepOrphanSnapshots(state, "", "", [state], site, (true, @[])).len == 0
    check keysOnHost(site) == @[failed.key]
  test "an unreadable marker: the sweep deletes nothing, and says so":
    let a = takeOne(state, site)
    createDir(parentDir(pendingMarkerPath(state)))
    writeFile(pendingMarkerPath(state), "not a pending marker\n")
    let l = sweepOrphanSnapshots(state, "", "", [state], site, (true, @[]))
    check l.len == 1 and l[0].startsWith($adSnapshotLeft)
    check "deleted nothing" in l[0] and "unreadable" in l[0]
    check keysOnHost(site) == @[a.key]
  test "a retained generation whose ownership cannot be read: nothing is deleted":
    let a = takeOne(state, site)
    let orphan = takeOne(state, site)
    createDir(parentDir(generationSnapshotPath(state, "g1")))
    writeFile(generationSnapshotPath(state, "g1"), "garbage\n")
    recordGenerationSnapshot(state, "g2", a.key)
    let l = sweepOrphanSnapshots(state, "g2", "g1", [state], site, (true, @["g2", "g1"]))
    check l.len == 1 and "deleted nothing" in l[0]
    check keysOnHost(site) == @[a.key, orphan.key]
    # A dropped generation's unreadable file owns nothing either way: it
    # does not stop the sweep.
    let l2 = sweepOrphanSnapshots(state, "g2", "g3", [state], site, (true, @["g2"]))
    check l2.len == 1 and "deleted the orphan" in l2[0]
    check keysOnHost(site) == @[a.key]
  test "a retained committed generation owns its snapshot; one retention dropped does not":
    let a = takeOne(state, site)
    let b = takeOne(state, site)
    let c = takeOne(state, site)
    recordGenerationSnapshot(state, "g1", a.key)
    recordGenerationSnapshot(state, "g2", b.key)
    recordGenerationSnapshot(state, "g3", c.key)
    # g3 current, g2 previous, g1's store root gone.
    discard sweepOrphanSnapshots(state, "g3", "g2", [state], site, (true, @["g3", "g2"]))
    check keysOnHost(site) == @[b.key, c.key]
  test "a generation with a store root and neither current nor previous is retained":
    let a = takeOne(state, site)
    recordGenerationSnapshot(state, "g1", a.key)
    discard sweepOrphanSnapshots(state, "g5", "g4", [state], site, (true, @["g1"]))
    check keysOnHost(site) == @[a.key]
  test "when the store's roots cannot be listed, every generation's snapshot is kept":
    let a = takeOne(state, site)
    let orphan = takeOne(state, site)
    recordGenerationSnapshot(state, "g1", a.key)
    discard sweepOrphanSnapshots(state, "g9", "g8", [state], site, (false, @[]))
    check keysOnHost(site) == @[a.key]
    discard orphan
  test "a snapshot this state never recorded is left alone (taken after the snapshot booted)":
    let a = takeOne(state, site)
    removeRecord(state, a.key)
    check sweepOrphanSnapshots(state, "", "", [state], site, (true, @[])).len == 0
    check keysOnHost(site) == @[a.key]
  test "booted into it under Omarchy's overlay: read from the kernel command line":
    let a = takeOne(state, site)
    var s2 = site
    s2.mountinfo = "46 1 0:40 / / rw,relatime shared:1 - overlay overlay " &
      "rw,lowerdir=/sysroot,upperdir=/run/omarchy-snapshot-overlay/upper\n"
    s2.cmdline = "root=PARTUUID=8791 zswap.enabled=0 rootflags=subvol=/@/.snapshots/" &
      $a.number & "/snapshot rw rootfstype=btrfs\n"
    check sweepOrphanSnapshots(state, "", "", [state], s2, (true, @[])).len == 0
    check keysOnHost(site) == @[a.key]
    check rootflagsSubvol(s2.cmdline) == "/@/.snapshots/" & $a.number & "/snapshot"
    check rootflagsSubvol("rootflags=compress=zstd,subvol=@ ro") == "@"
    check rootflagsSubvol("quiet") == ""
  test "the snapshot / runs from is left alone, its unowned record and all":
    let a = takeOne(state, site)
    var s2 = site
    s2.mountinfo = "29 1 0:24 /@/.snapshots/" & $a.number & "/snapshot / rw - " &
      "btrfs /dev/vda2 rw\n"
    check sweepOrphanSnapshots(state, "", "", [state], s2, (true, @[])).len == 0
    check keysOnHost(site) == @[a.key]
    check readRecords(state).len == 1
  test "a record whose snapshot is gone is removed":
    let a = takeOne(state, site)
    removeDir(f.snapDir(a.number))
    check sweepOrphanSnapshots(state, "", "", [state], site, (true, @[])).len == 0
    check readRecords(state).len == 0
  test "a failed deletion is reported each time and retried":
    discard takeOne(state, site)
    f.failDelete = true
    for i in 1 .. 2:
      let l = sweepOrphanSnapshots(state, "", "", [state], site, (true, @[]))
      check l.len == 1 and l[0].startsWith($adSnapshotLeft)
    f.failDelete = false
    check sweepOrphanSnapshots(state, "", "", [state], site, (true, @[])).len == 1
    check keysOnHost(site).len == 0
  test "nothing recorded: the sweep does not even look":
    discard f.omarchySnapshot()
    check sweepOrphanSnapshots(state, "", "", [state], site, (true, @[])).len == 0
    check f.calls.len == 0

suite "the sweep's call sites: recovery and the apply's pending check":
  setup:
    var (f, site, state) = newSite("callsites")
    putEnv(HostApplyLockEnvVar, f.root / "apply.lock")
  teardown:
    delEnv(HostApplyLockEnvVar)
  test "a recovery that finds no marker sweeps, and reports what it deleted":
    let a = takeOne(state, site)
    let r = recoverPendingSwitch(state, atBoot = false, site = site)
    check r.resolved and r.swept.len == 1
    check r.swept[0] == "deleted the orphan root snapshot root#" & $a.number &
      " (repro-addon=" & a.key & ")"
    check keysOnHost(site).len == 0
  test "a recovery that leaves the marker for an operator sweeps nothing":
    let a = takeOne(state, site)
    createDir(parentDir(pendingMarkerPath(state)))
    writeFile(pendingMarkerPath(state), "not a pending marker\n")
    let r = recoverPendingSwitch(state, atBoot = false, site = site)
    check not r.resolved
    check r.swept.len == 1 and r.swept[0].startsWith($adSnapshotLeft)
    check keysOnHost(site) == @[a.key]
  test "the apply's pending check sweeps and hands back what it reported":
    let a = takeOne(state, site)
    let noRecovery: SwitchRecovery = proc (dir: string): RecoveryOutcome
        {.closure, gcsafe.} = RecoveryOutcome(resolved: true)
    let g = checkPendingSwitches(state, noRecovery,
      pointer = f.root / "no-pointer", site = site)
    check g.ok
    check g.notes == @["deleted the orphan root snapshot root#" & $a.number &
      " (repro-addon=" & a.key & ")"]
    check keysOnHost(site).len == 0

suite "retention and uninstall":
  test "retention deletes exactly the dropped generations' snapshots":
    var (f, site, state) = newSite("retention")
    let a = takeOne(state, site)
    let b = takeOne(state, site)
    recordGenerationSnapshot(state, "g1", a.key)
    recordGenerationSnapshot(state, "g2", b.key)
    let o = f.omarchySnapshot()
    let l = deleteGenerationSnapshots(state, ["g1", "g0-without-one"], site)
    check l.len == 1 and "of generation g1" in l[0]
    check keysOnHost(site) == @[b.key] and dirExists(f.snapDir(o))
  test "uninstall deletes every repro-addon snapshot, recorded or not, and no other":
    var (f, site, state) = newSite("uninstall")
    let a = takeOne(state, site)
    let o = f.omarchySnapshot()
    let b = takeOne(state, site)
    removeRecord(state, b.key)
    # One in another configuration too.
    put(f.root, "etc/snapper/configs/home", "SUBVOLUME=\"/home\"\n")
    put(f.root, "home/.snapshots/1/info.xml", infoXml(1, "d", "repro-addon", "x"))
    let u = deleteEveryAddonSnapshot(state, site)
    check u.errors.len == 0 and u.deleted.len == 3
    check addonSnapshotsOnHost(site).len == 0
    check dirExists(f.snapDir(o))
    discard a
  test "an uninstall that cannot delete one reports it":
    var (f, site, state) = newSite("uninstall-fail")
    discard takeOne(state, site)
    f.failDelete = true
    let u = deleteEveryAddonSnapshot(state, site)
    check u.errors.len == 1 and u.errors[0].startsWith($adSnapshotLeft)
    check "uninstall" in u.errors[0]

suite "the /repro subvolume's mount (spec §5.1, AR4)":
  test "a btrfs root: the device by UUID and /repro below the root's subvolume":
    let d = base / "byuuid"
    removeDir(d)
    createDir(d / "dev")
    writeFile(d / "dev/vda2", "")
    createDir(d / "by-uuid")
    createSymlink(d / "dev/vda2", d / "by-uuid/3504834b")
    let omarchy = "29 1 0:24 /@ / rw,relatime shared:1 - btrfs " & d &
      "/dev/vda2 rw,subvol=/@\n31 29 0:25 /@home /home rw - btrfs " & d &
      "/dev/vda2 rw\n"
    let m = reproSubvolumeMountFor(omarchy, d / "by-uuid")
    check m.what == d / "by-uuid/3504834b" and m.subvol == "/@/repro"
    let top = "29 1 0:24 / / rw - btrfs " & d & "/dev/vda2 rw,subvolid=5\n"
    check reproSubvolumeMountFor(top, d / "by-uuid").subvol == "/repro"
  test "not btrfs, an overlay, or no UUID link: none":
    let d = base / "byuuid"
    check reproSubvolumeMountFor("29 1 254:1 / / rw - ext4 /dev/vda1 rw\n",
                                 d / "by-uuid").what == ""
    check reproSubvolumeMountFor("46 1 0:40 / / rw - overlay overlay " &
      "rw,lowerdir=/sysroot\n", d / "by-uuid").what == ""
    check reproSubvolumeMountFor("29 1 0:24 /@ / rw - btrfs /dev/vdb1 rw\n",
                                 d / "by-uuid").what == ""
  test "generation 0 has repro.mount exactly when the inputs name a subvolume":
    let exe = "/repro/store/prefixes/repro-addon/1-0123456789abcdef/bin/repro"
    var names: seq[string]
    let m = ReproSubvolumeMount(what: "/dev/disk/by-uuid/u", subvol: "/@/repro")
    var withMount: string
    for o in generation0Objects(Gen0Inputs(reproExe: exe, reproSubvolume: m)):
      names.add(o.unit)
      if o.unit == ReproMountUnit: withMount = o.content
    check ReproMountUnit in names
    check names.find(ReproMountUnit) < names.find(StoreMountUnit)
    check "What=/dev/disk/by-uuid/u\n" in withMount
    check "Where=/repro\n" in withMount and "Options=subvol=/@/repro\n" in withMount
    check "WantedBy=repro-addon.target" in withMount
    names.setLen(0)
    for o in generation0Objects(Gen0Inputs(reproExe: exe)): names.add(o.unit)
    check ReproMountUnit notin names

suite "the pending marker's snapshot fields":
  test "they round-trip, and a marker without them reads as before":
    let m = PendingMarker(fromGeneration: "g1", step: ssPreStop,
      status: "in-progress", purpose: "revert",
      rootSnapshot: "0123456789abcdef0123456789abcdef",
      revertSnapshot: "fedcba9876543210fedcba9876543210")
    let back = parsePendingMarker(m.render())
    check back.rootSnapshot == m.rootSnapshot
    check back.revertSnapshot == m.revertSnapshot
    let plain = PendingMarker(fromGeneration: "g1", step: ssPreStop)
    check "snapshot" notin plain.render()
    check parsePendingMarker(plain.render()).rootSnapshot == ""

removeDir(base)

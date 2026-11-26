## The add-on after the A9 review's round 17 (ReproOS Add-On Mode spec
## §6.2 step 4, §10.1; the re-assert unit re-pointed at the upgrading
## engine, §13 decision 164; the boot-hold unit required by sysinit.target,
## decision 172; the agent's units re-pointed, decision 173; only the static
## image installed, decision 174; the reviewer's probes ``probe17/p_repoint_revert.nim``, ``p_boot_order17.nim`` and
## ``p_delay17.nim``):
##
## - finding 1 (§13 decision 164 as amended): a revert or a rollback, whose
##   target generation's own profile names an older engine than the units
##   on disk, accepts any add-on rendering of a unit for an engine the
##   ledger records and keeps the newest engine; it never re-points
##   backwards;
## - §13 decision 173: the agent's apply and fetch units are re-pointed
##   with the re-assert and boot-confirm units, each by the same disk and
##   ledger check (finding 9, the boot-confirm unit);
## - §13 decision 174: only a static add-on image is installed
##   (``isStaticElf``);
## - §13 decision 172: the boot-hold unit is ``RequiredBy=sysinit.target``,
##   never fails, and an ordering of the profile that reaches what it
##   follows is refused, at parse time and on the effective unit; systemd's
##   own transaction keeps its job (``systemd-analyze verify``);
## - finding 6: an empty ``Before=`` resets nothing;
## - finding 7: a template's instances a revert stopped come back when
##   enabled;
## - finding 8: every systemd time unit is read, and the restart delay is
##   systemd's ``long double`` arithmetic.
##
## Falsifying builds, red here: ``repoint-backwards``, ``repoint-dynamic-engine``,
## ``reassert-not-repointed``, ``boot-hold-wanted``,
## ``boot-hold-cycle-parse-unchecked``,
## ``boot-hold-cycle-effective-unchecked``, ``deps-empty-resets``,
## ``revert-stopped-not-restarted``, ``timespan-units-partial``.
## ``revert-stopped-instances-unrecorded`` and ``revert-stopped-cleared-early``
## act in the procedures the switch calls at a template's running instances
## and around step 7 (``revertUnitsToStop``, ``planRevertStoppedStarts``,
## ``finishRevertStopped``), and are red in ``t_addon_floor_round22`` (A9
## review round 22); the record's selection of instances is
## ``revertStoppedToStart``, tested below.
##
## *Mocking.* The re-point's file-system probe and the committed ledger's
## digests are closures, so a revert's disk state can be stated exactly;
## the VM gate ``t_e2e_addon_boot_hold_reaches_existing_hosts`` drives the
## same code on a real host. The effective half is given ``systemctl show``
## text and an ``orderedBeforeOf`` closure: the rule is a function of what
## systemd reports, and the gates run it against systemd 252 and 257. The
## static-image check reads ELF headers this file writes, laid out as the
## System V gABI says. The transaction test runs the host's own
## ``systemd-analyze verify`` over unit files in a temporary directory; it is
## skipped where the host has none.

import std/[os, osproc, sequtils, sets, strutils, tempfiles, unittest]

from repro_core import ReprobuildVersion

import repro_test_support/reasoned_skip
import repro_infra/errors
import repro_infra/service_floor
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/store_root

const
  E1 = "/repro/store/prefixes/repro-addon/0.2.20-aaaaaaaaaaaaaaaa/bin/repro"
  E2 = "/repro/store/prefixes/repro-addon/0.2.25-bbbbbbbbbbbbbbbb/bin/repro"
  E3 = "/repro/store/prefixes/repro-addon/0.2.26-cccccccccccccccc/bin/repro"
  S = 1_000_000_000'i64
  Prefix = "/repro/store/prefixes/svc/1.0"

proc ownFor(exe: string): string =
  ## With a sink and the egress observer, so the shipping and egress check
  ## units, re-pointed since the owner's decision of 2026-11-26, are among
  ## the units every case checks.
  let agent = AgentUnitsInputs(target: "https://deploy.example/h",
                               sources: @["https://deploy.example/m"],
                               allowedAddresses: @["192.0.2.1"])
  renderOwnProfile(generation0Objects(Gen0Inputs(reproExe: exe, agent: agent,
    egress: EgressObserverInputs(nft: "/usr/sbin/nft",
                                 allowedAddresses: agent.allowedAddresses),
    evidence: EvidenceUnitsInputs(sinkAddress: "192.0.2.9", sinkPort: 7443))),
    "/f")

suite "A9 review round 17, finding 1: a revert or rollback after a re-point":
  # The target generation (committed before the re-point) names E1; the
  # units on disk, and the ledger's record of them, are E2's.
  let g1 = ownFor(E1)
  let g2 = ownFor(E2)
  proc disk(own: string): proc (p: string): tuple[present: bool; sha256: string] =
    let o = own
    result = proc (p: string): tuple[present: bool; sha256: string] =
      for u in RepointedUnits:
        if p == unitPath(u):
          let c = unitContentOf(o, u)
          if c.len > 0: return (true, sha256Hex(c))
      (false, "")
  proc ledger(own: string): proc (p: string): string =
    let d = disk(own)
    result = proc (p: string): string = d(p).sha256
  test "the reviewer's probe: accepted, and the units keep the newest engine":
    let r = repointEngine(g1, E2, [E1, E2], disk(g2), ledger(g2))
    check r.exe == E2
    check r.onDisk == E2
    check r.changed
    for u in RepointedUnits:
      check unitContentOf(r.own, u) == unitContentOf(g2, u)
  test "the dynamic engine applies (no static image): the units keep the one on disk":
    let r = repointEngine(g1, "", [E1, E2], disk(g2), ledger(g2))
    check r.exe == E2
    for u in RepointedUnits:
      check unitContentOf(r.own, u) == unitContentOf(g2, u)
  test "an older engine applies: never re-pointed backwards":
    let r = repointEngine(g1, E1, [E1, E2], disk(g2), ledger(g2))
    check r.exe == E2
    for u in RepointedUnits:
      check engineExeIn(unitContentOf(r.own, u)) == E2
  test "a newer engine than any recorded: re-pointed forwards, every unit":
    let r = repointEngine(g1, E3, [E1, E2], disk(g2), ledger(g2))
    check r.exe == E3
    for u in RepointedUnits:
      check unitContentOf(r.own, u) == unitContentOf(ownFor(E3), u)
  test "a rendering for an engine the ledger does not record is refused":
    expect ValueError:
      discard repointEngine(g1, E2, [E1], disk(ownFor(E3)), ledger(ownFor(E3)))
  test "finding 9: the boot-confirm unit is checked on disk and in the ledger":
    let d = disk(g2)
    expect ValueError:
      discard repointEngine(g1, E2, [E1, E2],
        proc (p: string): tuple[present: bool; sha256: string] =
          if p == unitPath(BootConfirmUnit): (true, sha256Hex("operator's")) else: d(p),
        ledger(g2))
    expect ValueError:
      discard repointEngine(g1, E2, [E1, E2], d,
        proc (p: string): string =
          if p == unitPath(BootConfirmUnit): "" else: d(p).sha256)

suite "A9 review round 17, finding 1: the units an upgrade adds, and a rollback past them":
  test "a unit not installed yet runs the engine the installed ones run":
    let g = ownFor(E1)
    proc d(p: string): tuple[present: bool; sha256: string] =
      if p == unitPath(BootConfirmUnit): return (false, "")
      for u in RepointedUnits:
        if p == unitPath(u): return (true, sha256Hex(unitContentOf(g, u)))
      (false, "")
    let r = repointEngine(g, E2, [E1], d, proc (p: string): string = d(p).sha256)
    check r.exe == E2
    check unitContentOf(r.own, BootConfirmUnit) == bootConfirmUnit(E2)
  test "only units the switch adds: they get the applying engine's image":
    let g = ownFor(E1)
    proc d(p: string): tuple[present: bool; sha256: string] = (false, "")
    let r = repointEngine(g, E2, [E1], d, proc (p: string): string = "")
    check engineExeIn(unitContentOf(r.own, BootConfirmUnit)) == E2
    check not repointEngine(g, "", [E1], d, proc (p: string): string = "").changed
  test "generation 0's upgrade path accepts a unit rendered for a recorded engine":
    # A rollback to a generation from before the boot-confirm unit: the own
    # profile lacks it, the host has it as E2's.
    let g2 = ownFor(E2)
    let onDisk = sha256Hex(unitContentOf(g2, BootConfirmUnit))
    let cand = @[OwnObject(kind: ookUnit, unit: BootConfirmUnit,
      path: unitPath(BootConfirmUnit), content: bootConfirmUnit(E1), enabled: true)]
    let probe = proc (p: string): tuple[present: bool; sha256: string] =
      if p == unitPath(BootConfirmUnit): (true, onDisk) else: (false, "")
    let rec = proc (p: string): string = probe(p).sha256
    let own = renderOwnProfile(generation0Objects(Gen0Inputs(reproExe: E1)).filterIt(
      it.unit != BootConfirmUnit), "/f")
    check BootConfirmUnit in addMissingGeneration0(own, cand, probe, rec, known = [E1, E2])
    expect ValueError:
      discard addMissingGeneration0(own, cand, probe, rec, known = [E1])

suite "§13 decision 173: the agent's units move with the re-assert unit":
  test "an upgrade re-points the agent-apply and fetch units":
    let g = ownFor(E1)
    proc d(p: string): tuple[present: bool; sha256: string] =
      for u in RepointedUnits:
        if p == unitPath(u): return (true, sha256Hex(unitContentOf(g, u)))
      (false, "")
    let r = repointEngine(g, E2, [E1], d,
      proc (p: string): string = d(p).sha256)
    check r.changed
    for u in [AgentApplyUnit, AgentFetchUnit]:
      check unitContentOf(g, u).len > 0
      check engineExeIn(unitContentOf(r.own, u)) == E2
      check E1 notin unitContentOf(r.own, u)
    check unitContentOf(r.own, AgentApplyUnit) == agentApplyUnit(E2)

suite "§13 decision 174: only the static add-on image is installed":
  proc elf(path: string; types: openArray[uint32]) =
    ## An ELF64 little-endian header with one program header per type.
    var b = newSeq[uint8](64 + 56 * types.len)
    for i, c in [0x7f'u8, uint8('E'), uint8('L'), uint8('F'), 2, 1, 1]: b[i] = c
    proc put(off, n: int; v: uint64) =
      for i in 0 ..< n: b[off + i] = uint8((v shr (8 * i)) and 0xff)
    put(0x10, 2, 2)                    # ET_EXEC
    put(0x20, 8, 64)                   # e_phoff
    put(0x36, 2, 56)                   # e_phentsize
    put(0x38, 2, uint64(types.len))    # e_phnum
    for i, t in types: put(64 + 56 * i, 4, t)
    var f = open(path, fmWrite)
    discard f.writeBytes(b, 0, b.len)
    f.close()
  test "no PT_INTERP is static; PT_INTERP, a script or nothing is not":
    let d = createTempDir("a9r17-", "-elf")
    defer: removeDir(d)
    elf(d / "static", [1'u32, 1])
    elf(d / "dynamic", [6'u32, 3, 1])
    writeFile(d / "script", "#!/bin/sh\nexit 0\n")
    check isStaticElf(d / "static")
    check not isStaticElf(d / "dynamic")
    check not isStaticElf(d / "script")
    check not isStaticElf(d / "absent")
  test "the choice: the static running image, a recorded static image of this version, or none":
    let mine = "/repro/store/prefixes/repro-addon/" & ReprobuildVersion & "-dddddddddddddddd/bin/repro"
    let old = "/repro/store/prefixes/repro-addon/0.0.1-eeeeeeeeeeeeeeee/bin/repro"
    let digest = proc (p: string): string = "ab".repeat(32)
    var c = repointEngineChoice("/usr/bin/repro-addon", [old],
      proc (p: string): bool = p == "/usr/bin/repro-addon", digest)
    check c.engineExe == reproExeFor("ab".repeat(32))
    check c.newImage == "/usr/bin/repro-addon"
    # The dynamic engine applies: the recorded static image of its version.
    c = repointEngineChoice("/nix/store/x-reprobuild/bin/reprobuild", [old, mine],
      proc (p: string): bool = p != "/nix/store/x-reprobuild/bin/reprobuild", digest)
    check c.engineExe == mine
    check c.newImage == ""
    # None of its version: skipped, and said so.
    c = repointEngineChoice("/nix/store/x-reprobuild/bin/reprobuild", [old],
      proc (p: string): bool = p != "/nix/store/x-reprobuild/bin/reprobuild", digest)
    check c.engineExe == ""
    check "not the static add-on image" in c.skipped
  test "the add-on's binary prefixes, oldest first, among the ledger's prefixes":
    check binaryPrefixesOf(["/repro/store/prefixes/repro-addon/0.2.20-a",
                            "/repro/store/prefixes/repro-addon-files/0.2.20-b",
                            "/repro/store/prefixes/repro-addon/0.2.25-c"]) ==
      @["/repro/store/prefixes/repro-addon/0.2.20-a/bin/repro",
        "/repro/store/prefixes/repro-addon/0.2.25-c/bin/repro"]

suite "§13 decision 172: the boot-hold unit is required by sysinit.target":
  let u = bootHoldUnit()
  test "never stopped or restarted at run time: inactive once run, manual stops refused":
    # A stop or a restart of a unit sysinit.target requires propagates to
    # every unit that requires sysinit.target (systemd.unit(5), Requires=).
    check "RemainAfterExit=no\n" in u
    check "RemainAfterExit=yes" notin u
    # RefuseManualStop= is a [Unit] key: in [Service] systemd ignores it.
    let unitSection = u.split("\n[Service]\n")[0]
    check "\nRefuseManualStop=yes\n" in unitSection
  test "RequiredBy=, and every path the script means exits 0":
    check "RequiredBy=sysinit.target\n" in u
    check "WantedBy=sysinit.target" notin u
    # A9 review round 20: no outer timeout. Round 21 (decision 172 as
    # amended 2026-11-21): no ``-`` either; every intended path exits 0.
    check "ExecStart=/bin/sh -c '" in u
    check "ExecStart=-" notin u
    check "TimeoutStartSec=60\n" in u
    let sc = bootHoldScript()
    # One non-zero exit only, and it ends the subshell that writes the
    # conservative list, not the script (round 22): the list that cannot
    # be written then takes the fail-closed path.
    check sc.count("exit 1") == 1
    check "echo $u.d || exit 1;;" in sc
    let listing = sc.find("( if [ $src = c ]; then ")
    check listing >= 0 and sc.find("exit 1") > listing and
      sc.find("exit 1") < sc.find(") > $l")
    for c in 2 .. 9:
      check ("exit " & $c) notin sc
    # Its last word is the fail-closed wait for TimeoutStartSec= (round 20).
    check sc.endsWith("exec /usr/bin/sleep 120")
  test "systemd's transaction keeps its job when a cycle runs through it":
    let analyze = findExe("systemd-analyze")
    if analyze.len == 0:
      skip("systemd-analyze not on PATH; this case runs systemd's own transaction")
    else:
      let d = createTempDir("a9r17-", "-units")
      defer: removeDir(d)
      # The unit as generation 0 renders it, its command replaced by one
      # every host has (verify checks that an ExecStart= is executable).
      var unit = ""
      for l in u.splitLines():
        if l.startsWith("ExecStart="): unit.add("ExecStart=/bin/sh -c true\n")
        elif l.len > 0 or unit.len > 0: unit.add(l & "\n")
      writeFile(d / BootHoldUnit, unit)
      let dir = if "RequiredBy=sysinit.target" in unit: "sysinit.target.requires"
                else: "sysinit.target.wants"
      createDir(d / dir)
      createSymlink(d / BootHoldUnit, d / dir / BootHoldUnit)
      # A socket the base installs (not the profile's: the profile's is
      # refused) closes a cycle through the boot-hold unit.
      writeFile(d / "a9cyc.service", "[Service]\nExecStart=/bin/sh -c true\n")
      # Before= the unit itself: a cycle through it alone (a longer one,
      # through local-fs.target, has systemd delete local-fs.target's job
      # whichever way the unit is installed, so it decides nothing).
      writeFile(d / "a9cyc.socket", "[Unit]\nBefore=" & BootHoldUnit & "\n" &
        "[Socket]\nListenStream=/run/a9cyc\n[Install]\nWantedBy=sockets.target\n")
      createDir(d / "sockets.target.wants")
      createSymlink(d / "a9cyc.socket", d / "sockets.target.wants" / "a9cyc.socket")
      writeFile(d / "a9-anchor.target", "[Unit]\nRequires=basic.target\nAfter=basic.target\n")
      let (o, _) = execCmdEx("env SYSTEMD_UNIT_PATH=" & d & ": " & analyze &
        " verify --man=no a9-anchor.target")
      checkpoint o
      check "to break ordering cycle" in o
      check ("Job " & BootHoldUnit & "/start deleted") notin o

proc parsed(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

let svc = "systemd.systemUnit {\n  name = \"a9q.service\"\n  content = \"[Unit]\n" &
  "Description=x\n\n[Service]\nUser=a\nExecStart=" & Prefix &
  "/bin/svc\n\"\n  enabled = false\n}\n"
proc sock(unitExtra: string; dropIn = ""; extra = ""): string =
  svc & extra & "systemd.systemUnit {\n  name = \"a9q.socket\"\n  content = \"[Unit]\n" &
    unitExtra & "\n[Socket]\nListenStream=/run/a9q\nService=a9q.service\n\n" &
    "[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n" &
    (if dropIn.len > 0:
       "systemd.systemDropIn {\n  unit = \"a9q.socket\"\n  name = \"10-x\"\n" &
       "  content = \"[Unit]\n" & dropIn & "\"\n}\n"
     else: "")
proc plain(name, unitExtra: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    unitExtra & "\n[Service]\nType=oneshot\nExecStart=/bin/true\n\"\n" &
    "  floorExceptions = [\"serviceFloor: a fixture\"]\n  enabled = false\n}\n"

suite "§13 decision 172, the parse half: no cycle through the boot-hold unit":
  test "the reviewer's orderings C, D, E, F and M are refused":
    for (label, text) in [
        ("C", sock("Before=systemd-remount-fs.service\n")),
        ("D", sock("Before=systemd-tmpfiles-setup.service\n")),
        ("E", sock("DefaultDependencies=no\nAfter=sysinit.target\nBefore=systemd-journald.service\n")),
        ("F", sock("Before=early.target\n", extra =
          "systemd.systemUnit {\n  name = \"early.target\"\n  content = \"[Unit]\n" &
          "DefaultDependencies=no\nBefore=local-fs.target\n\"\n}\n")),
        ("M", sock("Before=-.mount\n"))]:
      let m = parsed(text)
      checkpoint label & " -> " & m
      check "ordering cycle" in m
  test "any unit, floored or not: a service with default dependencies before a mount":
    check "ordering cycle" in parsed(plain("a9m.service", "Before=var.mount\n"))
    check "ordering cycle" in parsed(plain("a9m.service", "Before=run-wrappers.mount\n"))
  test "without default dependencies and not after sysinit.target, it is no cycle":
    check parsed(plain("a9m.service", "DefaultDependencies=no\nBefore=-.mount\n")) == ""
  test "after basic.target, or after sysinit.target, passes":
    check parsed(sock("DefaultDependencies=no\nAfter=basic.target\n")) == ""
    check parsed(sock("DefaultDependencies=no\nAfter=sysinit.target\n")) == ""

suite "§13 decision 172, the effective half: what systemd reports":
  let base = "FragmentPath=/etc/systemd/system/a9q.socket\nTriggers=a9q.service\n"
  proc probs(extra: string; before: proc (u: string): seq[string]): string =
    activatorProblems("a9q.socket", parseShow(base & extra),
      parseShowLines("Listen=/run/a9q (Stream)\n"),
      "/etc/systemd/system/a9q.socket", [], orderedBeforeOf = before).join("\n")
  test "a chain of Before= to what the boot-hold unit follows is refused":
    let m = probs("After=sysinit.target\nBefore=a9x.service sockets.target\n",
      proc (u: string): seq[string] =
        if u == "a9x.service": @["run-wrappers.mount"]
        elif u == "run-wrappers.mount": @["local-fs.target"]
        else: @[])
    checkpoint m
    check "[rule:boot-hold-cycle" in m
    check "a9q.socket -> a9x.service -> run-wrappers.mount" in m
  test "the default order passes":
    check "[rule:boot-hold-cycle" notin probs(
      "After=sysinit.target\nBefore=sockets.target shutdown.target\n",
      proc (u: string): seq[string] =
        if u == "sockets.target": @["basic.target"] else: @[])

suite "A9 review round 17, finding 6: an empty Before= resets nothing":
  test "the reviewer's A and B: the file's Before= stays in force":
    check "repro-addon-boot-hold.service" in
      parsed(sock("Before=repro-addon-boot-hold.service\n", dropIn = "Before=\n"))
    check "sysinit.target" in parsed(sock(
      "DefaultDependencies=no\nAfter=sysinit.target\nBefore=sysinit.target\n",
      dropIn = "Before=\n"))
  test "the shared rule over the files":
    check activatorBootOrderOfFiles("a.socket",
      ["[Unit]\nBefore=sysinit.target\n", "[Unit]\nBefore=\n"]).len > 0
    check activatorBootOrderOfFiles("a.socket",
      ["[Unit]\nDefaultDependencies=no\nAfter=sysinit.target\n", "[Unit]\nAfter=\n"]) == ""

suite "A9 review round 17, finding 7: a template's instances come back":
  test "an instance the revert stopped is started unless a socket starts it":
    # A9 review round 18, L1: an instance another unit's Wants= pulled in
    # (not enabled) comes back too; one a socket with Accept=yes started is
    # left to its socket.
    # A9 review round 19, finding 2: a stopped instance is collected, so
    # systemd reports no TriggeredBy= for it; the socket that starts it is
    # read from the generation (``acceptSocketTemplates``). Here a@y is an
    # instance of the template an Accept=yes socket starts, a@x of a
    # template none does.
    let gen = toHashSet(["a@.service", "s@.service", "b.service"])
    let accept = toHashSet(["s@.service"])
    let up = revertStoppedToStart(["a@x.service", "s@y.service", "b.service",
                                   "c@z.service"],
      gen, [], proc (u: string): bool = false,
      proc (u: string): bool =
        instanceSocketActivated(u, accept, proc (w: string): seq[string] = @[]))
    check up == @["a@x.service", "b.service"]

suite "A9 review round 17, finding 8: every systemd time unit":
  test "days, weeks, months and years, as systemctl show prints them":
    check parseTimespanNs("1d") == 86_400 * S
    check parseTimespanNs("1w 2d") == (7 + 2) * 86_400 * S
    check parseTimespanNs("1month") == 2_629_800 * S
    check parseTimespanNs("1M") == 2_629_800 * S
    check parseTimespanNs("1y") == 31_557_600 * S
    check parseTimespanNs("2h 1min") == 7_260 * S
    check parseTimespanNs("1min30s") == 90 * S
    check parseTimespanNs("1.5s") == 1_500_000_000
    check parseTimespanNs("5μs") == 5_000
    check parseTimespanNs("3 weeks") == 21 * 86_400 * S
    check parseTimespanNs("1x") == -1
    check parseTimespanNs("s") == -1
  test "a restart delay with a maximum of a day":
    let r = parseUnitRun("NRestarts=2\nRestartUSec=100ms\nRestartSteps=5\n" &
      "RestartMaxDelayUSec=1d\n")
    check r.restartDelay > 100_000_000
  test "systemd's long double arithmetic: 1 s to 8 s in 3 steps, step 2 is 4 s":
    check restartDelayBefore(3, 1 * S, 8 * S, 3) == 4 * S

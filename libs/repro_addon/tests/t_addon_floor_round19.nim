## The add-on after the A9 review's round 19 (ReproOS Add-On Mode spec
## §6.2 step 4, §10.1; §13 decisions 172, 173 and 174):
##
## - B1: the re-point compares the units on disk with the own profile as
##   stored on the host and this build's migration of it, besides the
##   target's text, so an apply whose target is a new own profile
##   (``agent-repin`` with new origins, ``evidence-enrol`` on an agent
##   host) re-points instead of refusing; foreign bytes are still refused;
## - finding 2: an ``Accept=yes`` instance a revert stopped is told by the
##   generation's sockets, not by ``TriggeredBy=``, which is empty once
##   systemd has collected the stopped instance;
## - finding 3 (the owner's decision of 2026-11-17, "Yes, check drop-ins"):
##   both halves of decision 172 and the stop-dependency refusal cover the
##   units the profile's drop-ins change; the effective half's every-unit
##   pass is driven here directly;
## - L4: ``Conflicts=`` / ``PropagatesStopTo=`` naming ``sysinit.target``
##   are refused;
## - L7: the preflight refuses a dynamically linked add-on binary, so
##   bootstrap installs the static image only.
##
## Falsifying builds, red here: ``repoint-stored-from-target``,
## ``accept-instances-by-triggered-by``, ``boot-hold-dropins-unchecked``,
## ``boot-hold-dropins-effective-unchecked``,
## ``boot-hold-cycle-every-unit-skipped``, ``sysinit-stop-deps-unchecked``,
## ``bootstrap-accepts-dynamic``.
##
## *Mocking.* The re-point's file-system probe and the ledger's digests are
## closures (the VM agent-tick, egress-observer and evidence-enrol gates
## drive the same code on a host); ``TriggeredBy=`` is a closure that
## answers as systemd does for a collected instance (nothing), which the
## round-17 test's mock did not; the effective pass is given
## ``systemctl show`` text per unit; the ELF files are written here with
## the headers ``isStaticElf`` reads.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_infra
import repro_infra/errors
import repro_addon/addon_apply
import repro_addon/agent_repin
import repro_addon/effective_floor
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/preflight

const
  E1 = "/repro/store/prefixes/repro-addon/0.2.20-aaaaaaaaaaaaaaaa/bin/repro"
  E2 = "/repro/store/prefixes/repro-addon/0.2.25-bbbbbbbbbbbbbbbb/bin/repro"

let agentInputs = AgentUnitsInputs(target: "https://deploy.example/h",
  sources: @["https://deploy.example/m"], allowedAddresses: @["192.0.2.1"])

proc ownOf(exe: string; observed = false): string =
  ## Generation 0's own profile with the deploy agent, with the egress
  ## observer's objects when ``observed`` (what `evidence-enrol` adds).
  var inp = Gen0Inputs(reproExe: exe, agent: agentInputs)
  if observed:
    inp.egress = EgressObserverInputs(nft: "/usr/sbin/nft",
      allowedAddresses: agentInputs.allowedAddresses)
  renderOwnProfile(generation0Objects(inp), "/f")

proc hostWith(onDisk: string): tuple[probe: PathProbe; rec: RecordedDigest] =
  ## The units on disk and the ledger's digests: those of ``onDisk``.
  let probe = proc (p: string): tuple[present: bool; sha256: string] =
    for u in RepointedUnits:
      if p == unitPath(u):
        let c = unitContentOf(onDisk, u)
        if c.len > 0: return (true, sha256Hex(c))
    (false, "")
  (probe, proc (p: string): string = probe(p).sha256)

proc attempt(onHost, target: string; engine = E2;
             onDisk = ""): tuple[ok: bool; exe, msg: string] =
  ## The re-point of an apply whose target own profile is ``target`` on a
  ## host that stores ``onHost`` (and whose units are ``onDisk``'s, by
  ## default ``onHost``'s), as ``runAddonApply`` drives it.
  let h = hostWith(if onDisk.len > 0: onDisk else: onHost)
  try:
    let r = repointEngine(migrateOwnProfile(target), engine, [E1], h.probe, h.rec,
                          stored = repointStoredTexts(onHost, target))
    (true, r.exe, "")
  except ValueError as e:
    (false, "", e.msg)

suite "A9 review round 19, B1: an apply that names a new own profile":
  let onHost = ownOf(E1)
  test "agent-repin with new origins re-points":
    var fresh = agentInputs
    fresh.allowedAddresses = @["192.0.2.9"]
    let plan = repinOwnProfile(onHost, fresh, "")
    check plan.changed
    let r = attempt(onHost, plan.ownText)
    checkpoint r.msg
    check r.ok and r.exe == E2
  test "evidence-enrol on an agent host re-points":
    let r = attempt(onHost, ownOf(E1, observed = true))
    checkpoint r.msg
    check r.ok and r.exe == E2
  test "a plain apply (the target is the stored text) re-points":
    check attempt(onHost, onHost).ok
  test "a fetch unit an older renderer wrote, under a new target":
    let fetch = unitContentOf(onHost, AgentFetchUnit)
    let older = replaceUnitContent(onHost, AgentFetchUnit,
      fetch.replace("[Service]\n", "[Service]\n# rendered by an older engine\n"))
    let r = attempt(older, ownOf(E1, observed = true))
    checkpoint r.msg
    check r.ok
  test "foreign bytes are still refused":
    let fetch = unitContentOf(onHost, AgentFetchUnit)
    let foreign = replaceUnitContent(onHost, AgentFetchUnit,
      fetch.replace("[Service]\n", "[Service]\nEnvironment=X=1\n"))
    let r = attempt(onHost, ownOf(E1, observed = true), onDisk = foreign)
    check not r.ok
    check "is not a repro-agent-fetch.service the add-on installed" in r.msg
  test "the accepted set: stored, its migration and nothing else":
    check repointStoredTexts("", "x") == newSeq[string]()
    let s = repointStoredTexts(onHost, ownOf(E1, observed = true))
    check s.len in 1 .. 2
    check s[0] == onHost
    if s.len == 2: check s[1] == migrateOwnProfile(onHost)

suite "A9 review round 19, finding 2: a collected Accept=yes instance":
  proc profileWith(socket: string; dropIn = ""): SystemProfile =
    var t = "systemd.systemUnit {\n  name = \"a9a@.service\"\n  content = \"" &
      "[Service]\nType=oneshot\nExecStart=/bin/true\nStandardInput=socket\n\"\n" &
      "  floorExceptions = [\"serviceFloor: a fixture\"]\n  enabled = false\n}\n" &
      "systemd.systemUnit {\n  name = \"a9a.socket\"\n  content = \"[Socket]\n" &
      socket & "\n[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n"
    if dropIn.len > 0:
      t.add("systemd.systemUnit {\n  name = \"a9a.socket\"\n  collision = \"dropIn\"\n" &
            "  content = \"[Socket]\n" & dropIn & "\n\"\n}\n")
    parseAddOnUserProfile(t)
  let collected = proc (u: string): seq[string] = @[]   # TriggeredBy=, empty
  test "an Accept=yes socket's instance is left to its socket":
    let acc = acceptSocketTemplates(profileWith("ListenStream=/run/a9a\nAccept=yes"))
    check "a9a@.service" in acc
    check instanceSocketActivated("a9a@3-1.service", acc, collected)
    let up = revertStoppedToStart(["a9a@3-1.service", "b@x.service"],
      toHashSet(["a9a@.service", "b@.service"]), [], proc (u: string): bool = false,
      proc (u: string): bool = instanceSocketActivated(u, acc, collected))
    check up == @["b@x.service"]
  test "Accept=yes set by the profile's drop-in counts":
    let acc = acceptSocketTemplates(profileWith("ListenStream=/run/a9a", "Accept=yes"))
    check "a9a@.service" in acc
  test "a socket without Accept= starts no instance":
    let acc = acceptSocketTemplates(profileWith("ListenStream=/run/a9a\nService=a9a@x.service"))
    check "a9a@.service" notin acc
    check not instanceSocketActivated("a9a@y.service", acc, collected)
  test "a base socket systemd still names in TriggeredBy= counts too":
    check instanceSocketActivated("c@1.service", initHashSet[string](),
      proc (u: string): seq[string] = @["c.socket"])

proc parsed(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

proc dropIn(unit, body: string): string =
  "systemd.systemUnit {\n  name = \"" & unit & "\"\n  collision = \"dropIn\"\n" &
    "  content = \"" & body & "\"\n}\n"

proc own(name, body: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" & body &
    "\n[Service]\nType=oneshot\nExecStart=/bin/true\n\"\n" &
    "  floorExceptions = [\"serviceFloor: a fixture\"]\n  enabled = false\n}\n"

suite "A9 review round 19, finding 3: the parse half covers drop-ins":
  test "a drop-in on a base unit naming the boot-hold unit in Conflicts=":
    check "names " & BootHoldUnit & " in Conflicts=" in
      parsed(dropIn("cron.service", "[Unit]\nConflicts=" & BootHoldUnit & "\n"))
  test "... in PropagatesStopTo=":
    check "in PropagatesStopTo=" in
      parsed(dropIn("cron.service", "[Unit]\nPropagatesStopTo=" & BootHoldUnit & "\n"))
  test "a drop-in ordering a base unit before systemd-remount-fs.service":
    check "an ordering cycle" in
      parsed(dropIn("cron.service", "[Unit]\nBefore=systemd-remount-fs.service\n"))
  test "an ordinary drop-in passes":
    check parsed(dropIn("cron.service", "[Unit]\nAfter=network-online.target\n" &
                        "Wants=network-online.target\n")) == ""

suite "A9 review round 19, L4: sysinit.target itself":
  test "Conflicts= and PropagatesStopTo= naming sysinit.target are refused":
    check "names sysinit.target in Conflicts=" in
      parsed(own("a9t.service", "[Unit]\nDefaultDependencies=no\nConflicts=sysinit.target\n"))
    check "names sysinit.target in PropagatesStopTo=" in
      parsed(dropIn("cron.service", "[Unit]\nPropagatesStopTo=sysinit.target\n"))
  test "StopPropagatedFrom= (the reverse) passes":
    check parsed(own("a9r.service", "[Unit]\nDefaultDependencies=no\n" &
                     "StopPropagatedFrom=" & BootHoldUnit & "\n")) == ""

suite "A9 review round 19, finding 3 and LOW: the effective every-unit pass":
  let res = @[
    SystemResource(kind: srkSystemdSystemUnit, suName: "a9p.service",
                   suContent: "[Service]\nExecStart=/bin/true\n"),
    SystemResource(kind: srkSystemdSystemUnit, suName: "cron.service",
                   suCollision: "dropIn", suContent: "[Unit]\nBefore=zfs-mount.service\n")]
  let cyc = "After=sysinit.target\nBefore=zfs-mount.service\n"
  let ok = "After=sysinit.target basic.target\nBefore=multi-user.target\n"
  let before = proc (u: string): seq[string] =
    if u == "zfs-mount.service": @["local-fs.target"] else: @[]
  proc run(cycles: openArray[string]): seq[string] =
    let c = @cycles
    everyUnitBootHoldProblems(res, initHashSet[string](),
      proc (n: string): tuple[ok: bool; show: ShowProps] =
        (true, parseShow(if n in c: cyc else: ok)), before)
  test "a plain unit of the generation that closes the cycle is refused":
    let p = run(["a9p.service"])
    checkpoint p.join("\n")
    check p.len == 1 and "a9p.service" in p[0] and "boot-hold-cycle" in p[0]
  test "a base unit the profile's drop-in orders into the cycle is refused":
    let p = run(["cron.service"])
    checkpoint p.join("\n")
    check p.len == 1 and "cron.service" in p[0]
  test "units the floor judged are not judged again; the default order passes":
    check run([]).len == 0
    check everyUnitBootHoldProblems(res, toHashSet(["a9p.service", "cron.service"]),
      proc (n: string): tuple[ok: bool; show: ShowProps] = (true, parseShow(cyc)),
      before).len == 0

suite "A9 review round 19, L7: bootstrap installs the static image only":
  proc elf(path: string; types: openArray[uint32]) =
    var b = newSeq[uint8](64 + 56 * types.len)
    b[0] = 0x7f; b[1] = uint8('E'); b[2] = uint8('L'); b[3] = uint8('F')
    b[4] = 2; b[5] = 1; b[6] = 1
    proc put(off, n: int; v: uint64) =
      for i in 0 ..< n: b[off + i] = uint8((v shr (8 * i)) and 0xff)
    put(0x10, 2, 2)
    put(0x20, 8, 64)
    put(0x36, 2, 56)
    put(0x38, 2, uint64(types.len))
    for i, t in types: put(64 + 56 * i, 4, t)
    var f = open(path, fmWrite)
    discard f.writeBytes(b, 0, b.len)
    f.close()
  test "the preflight's check passes the static image and refuses the dynamic engine":
    let d = createTempDir("a9r19-", "-elf")
    defer: removeDir(d)
    elf(d / "static", [1'u32, 1])
    elf(d / "dynamic", [6'u32, 3, 1])
    check binaryStaticCheck(d / "static").ok
    let dyn = binaryStaticCheck(d / "dynamic")
    check not dyn.ok
    check "bootstrap with the static add-on image" in dyn.detail

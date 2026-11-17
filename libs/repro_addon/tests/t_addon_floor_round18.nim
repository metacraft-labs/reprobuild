## The add-on after the A9 review's round 18 (ReproOS Add-On Mode spec
## §6.2 step 4, §10.1; the boot-hold unit required by sysinit.target and
## its residual, §13 decision 172; the agent's units re-pointed, decision
## 173):
##
## - B1: the re-point accepts a unit on disk rendered from the own profile
##   as stored, before this build migrated it (a fetch unit an engine with
##   another fetch renderer wrote), not only from the migrated text;
## - M1: ``repro system addon verify`` reports a ``sysinit.target.requires``
##   link naming the boot-hold unit that dangles, or a unit systemd cannot
##   load;
## - M2: the effective half of decision 172 judges any unit of the
##   generation, a plain unit too;
## - L4: Conflicts= or PropagatesStopTo= naming the boot-hold unit is
##   refused.
##
## Falsifying builds, red here: ``repoint-migrated-only``,
## ``verify-ignores-boot-hold-link``, ``boot-hold-cycle-effective-unchecked``,
## ``boot-hold-stop-deps-unchecked``. ``uninstall-leaves-boot-hold-requires``
## acts on the host's /etc and is red in the VM gate
## ``t_e2e_addon_boot_hold_reaches_existing_hosts``.
##
## *Mocking.* The re-point's file-system probe and the ledger's digests are
## closures (the VM upgrade gate drives the same code); the verify check is
## given a temporary unit directory and the LoadState systemd would report;
## the effective rule is given ``systemctl show`` text and an
## ``orderedBeforeOf`` closure.

import std/[os, strutils, tempfiles, unittest]

import repro_infra/errors
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/verify

const
  E1 = "/repro/store/prefixes/repro-addon/0.2.20-aaaaaaaaaaaaaaaa/bin/repro"
  E2 = "/repro/store/prefixes/repro-addon/0.2.25-bbbbbbbbbbbbbbbb/bin/repro"

proc ownFor(exe: string): string =
  renderOwnProfile(generation0Objects(Gen0Inputs(reproExe: exe,
    agent: AgentUnitsInputs(target: "https://deploy.example/h",
                            sources: @["https://deploy.example/m"],
                            allowedAddresses: @["192.0.2.1"]))), "/f")

suite "A9 review round 18, B1: a fetch unit an older renderer wrote":
  # The host's own profile as stored: its fetch unit as an engine with
  # another renderer wrote it (here, the current rendering with a line the
  # current renderer does not write). This build migrates it.
  let current = ownFor(E1)
  let fetchNow = unitContentOf(current, AgentFetchUnit)
  let fetchOld = fetchNow.replace("[Service]\n", "[Service]\n# rendered by an older engine\n")
  let stored = replaceUnitContent(current, AgentFetchUnit, fetchOld)
  let migrated = migrateOwnProfile(stored)
  proc disk(p: string): tuple[present: bool; sha256: string] =
    for u in RepointedUnits:
      if p == unitPath(u):
        let c = unitContentOf(stored, u)
        if c.len > 0: return (true, sha256Hex(c))
    (false, "")
  proc rec(p: string): string = disk(p).sha256
  test "premise: the migration re-renders the stored fetch unit":
    check fetchOld != fetchNow
    check unitContentOf(migrated, AgentFetchUnit) != fetchOld
  test "the upgrade accepts it and re-points the migrated unit":
    let r = repointEngine(migrated, E2, [E1], disk, rec, stored = [stored])
    check r.exe == E2
    check unitContentOf(r.own, AgentFetchUnit) ==
      unitContentOf(migrated, AgentFetchUnit).replace(E1, E2)
  test "a foreign fetch unit is still refused":
    expect ValueError:
      discard repointEngine(migrated, E2, [E1],
        proc (p: string): tuple[present: bool; sha256: string] =
          if p == unitPath(AgentFetchUnit): (true, sha256Hex("operator's")) else: disk(p),
        proc (p: string): string =
          if p == unitPath(AgentFetchUnit): sha256Hex("operator's") else: rec(p),
        stored = [stored])

suite "A9 review round 18, M1: verify reports a dangling requires link":
  test "a link to nothing, or a unit systemd cannot load, is drift":
    let d = createTempDir("a9r18-", "-units")
    defer: removeDir(d)
    createDir(d / "sysinit.target.requires")
    let link = d / "sysinit.target.requires" / BootHoldUnit
    check bootHoldLinkFinding(d, proc (): string = "loaded") == ""
    createSymlink(d / BootHoldUnit, link)
    check "is not a unit file" in bootHoldLinkFinding(d, proc (): string = "loaded")
    writeFile(d / BootHoldUnit, "[Unit]\n")
    check bootHoldLinkFinding(d, proc (): string = "loaded") == ""
    check "LoadState" in bootHoldLinkFinding(d, proc (): string = "not-found")

suite "A9 review round 18, M2: any unit of the generation":
  test "a plain unit after the boot-hold unit and before zfs-mount.service":
    let show = parseShow("After=repro-addon-boot-hold.service\n" &
                         "Before=zfs-mount.service\n")
    let why = bootHoldCycleOf("a9p.service", show,
      proc (u: string): seq[string] =
        if u == "zfs-mount.service": @["local-fs.target"] else: @[])
    checkpoint why
    check "a9p.service -> zfs-mount.service -> local-fs.target" in why
  test "the default order passes":
    check bootHoldCycleOf("a9p.service",
      parseShow("After=sysinit.target basic.target\nBefore=shutdown.target multi-user.target\n"),
      proc (u: string): seq[string] = @[]) == ""

proc parsed(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

proc plain(extra: string): string =
  "systemd.systemUnit {\n  name = \"a9s.service\"\n  content = \"[Unit]\n" &
    extra & "\n[Service]\nType=oneshot\nExecStart=/bin/true\n\"\n" &
    "  floorExceptions = [\"serviceFloor: a fixture\"]\n  enabled = false\n}\n"

suite "A9 review round 18, L4: nothing may stop the boot-hold unit":
  test "Conflicts= or PropagatesStopTo= naming it is refused":
    for k in ["Conflicts", "PropagatesStopTo"]:
      let m = parsed(plain("DefaultDependencies=no\n" & k & "=" & BootHoldUnit & "\n"))
      checkpoint k & " -> " & m
      check ("in " & k & "=") in m
  test "naming another unit passes":
    check parsed(plain("Conflicts=shutdown.target\n")) == ""

## Every kind spec §8.3 ("As implemented (A6)") lists for an add-on profile
## goes through the add-on switch (reprobuild-pm issue
## 2026-10-31-addon-switch-refuses-kinds-the-spec-lists-as-valid):
## `systemd.systemTimer`, `passwd.user`, `passwd.group` and
## `linux.addOnTool`, beside the kinds the switch managed before. The VM
## gate ``e2e_addon_agent_generations_and_rollback`` migrates a host that
## carries all four; this file pins the decisions that need no root:
##
## * the scope check accepts the four and still refuses the kinds §8.3
##   lists as invalid (and the firewall class, refused until §13 Q6);
## * their names are checked before anything is observed;
## * a tool's wrapper and launcher manifest are the bytes its driver
##   renders, under the tool's address;
## * an account is decided the way its driver compares it (the masked
##   observation, reprobuild 1ad1f593c8): absent creates, as declared
##   adopts (or is the ledger's no-op, reported as accepted out of band
##   when it moved), otherwise updates the ledger's and refuses another's.
##
## At reprobuild 59c075685f the scope check refused all four kinds (the
## first test fails there) and none of the other procs existed.
##
## MOCK JUSTIFICATION. None: the accounts are the build host's own `root`
## group and user, read through the real passwd driver; the tool's bytes
## come from the real driver's renderers.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/apt_closure
import repro_elevation/posix_system_driver
import repro_infra
import repro_infra/addon_diagnostics
import repro_addon/addon_apply
import repro_addon/agent_record
import repro_addon/collision

let Lock = renderAptClosureLock(AptClosureLock(
  archive: "http://fixture.invalid/debian", suite: "fixture",
  components: @["main"], architecture: "amd64", snapshot: "",
  inReleaseSha256: "c".repeat(64),
  indexes: @[AptIndexDigest(path: "main/binary-amd64/Packages.xz",
                            sha256: "d".repeat(64))],
  roots: @["ipmitool"],
  debs: @[AptLockedDeb(name: "ipmitool", version: "1.0-1",
    architecture: "amd64", filename: "pool/main/ipmitool_1.0-1_amd64.deb",
    size: 1, sha256: "e".repeat(64))]))

proc timer(name: string; enabled = true; running = true): SystemResource =
  SystemResource(kind: srkSystemdSystemTimer, address: "systemTimer:" & name,
    stName: name, stContent: "[Timer]\nOnCalendar=daily\n",
    stEnabled: enabled, stRunning: running)

proc group(name: string; gid = ""; members: seq[string] = @[]): SystemResource =
  SystemResource(kind: srkPasswdGroup, address: "group:" & name,
    pgName: name, pgGid: gid, pgMembers: members)

suite "the kinds §8.3 lists are in the add-on's scope":
  test "timer, accounts and tool are accepted; the invalid kinds are not":
    let prof = SystemProfile(resources: @[timer("backup.timer"),
      group("root", "0"),
      SystemResource(kind: srkPasswdUser, address: "user:root",
        puName: "root"),
      SystemResource(kind: srkLinuxAddOnTool, address: "addOnTool:ipmitool",
        atCommand: "ipmitool", atAptClosureLock: Lock,
        atProgram: "/usr/bin/ipmitool")])
    checkScope(prof)               # raises EAddOnOutOfScope at 59c075685f
    for k in [srkLinuxFirewallRule, srkLinuxUdevRule, srkOsHostname,
              srkFsSystemDirectory]:
      check unmanagedKindReason(SystemResource(kind: k)).len > 0

  test "their names are checked first":
    check addOnNameError(timer("backup.timer")) == ""
    check "does not end in .timer" in addOnNameError(timer("backup.service"))
    check "enabled and started, or neither" in
      addOnNameError(timer("backup.timer", enabled = true, running = false))
    check addOnNameError(timer("backup.timer", false, false)) == ""
    check addOnNameError(group("bad/name")).len > 0
    check addOnNameError(SystemResource(kind: srkLinuxAddOnTool,
      atCommand: "-x")).len > 0

suite "a tool is ledgered through the two files it writes":
  test "the carriers are the driver's bytes, under the tool's address":
    let t = SystemResource(kind: srkLinuxAddOnTool,
      address: "addOnTool:ipmitool", atCommand: "ipmitool",
      atAptClosureLock: Lock, atProgram: "/usr/bin/ipmitool")
    let c = addOnToolCarriers(t)
    check c.len == 2
    check c[0].sfPath == addOnToolWrapperPath("ipmitool")
    check c[0].sfContent ==
      renderAddOnToolWrapper(addOnToolManifestPath("ipmitool"))
    check c[1].sfPath == addOnToolManifestPath("ipmitool")
    check c[1].sfContent == renderAddOnToolManifest(
      aptClosurePrefixPath(AddOnSystemStoreRoot, parseAptClosureLock(Lock)),
      "/usr/bin/ipmitool")
    for x in c: check addOnToolCarrierOf(x) == "addOnTool:ipmitool"
    check addOnToolCarrierOf(SystemResource(kind: srkFsSystemFile,
      address: "systemFile:/etc/x")) == ""

suite "an account is decided as its driver compares it":
  test "absent creates; as declared adopts, or is the ledger's no-op":
    check decideAccount(group("repro-no-such-group-7c1e"), "", false, false,
                        false).verdict == cvCreate
    let root = group("root", "0")
    let now = accountFingerprintValue("group", "root")
    check decideAccount(root, "", false, false, false).verdict == cvAdopt
    let owned = decideAccount(root, now, true, false, false)
    check owned.verdict == cvNoOp and not owned.acceptedOutOfBand
    # The ledger recorded other bytes and the account is as declared now:
    # accepted out of band, still a no-op (spec §4.3).
    let moved = decideAccount(root, now & "-before", true, false, false)
    check moved.verdict == cvNoOp and moved.acceptedOutOfBand

  test "members are a subset requirement; a pinned gid is compared":
    # root's live members, whatever they are, are not compared when the
    # resource declares none (1ad1f593c8).
    check decideAccount(group("root"), "", false, false, false).verdict ==
      cvAdopt
    let other = group("root", "4242")
    check decideAccount(other, "x", true, false, false).verdict == cvUpdate
    expect AddonDriftError:
      discard decideAccount(other, "", false, false, false)
    check decideAccount(other, "", false, true, false).verdict == cvReconcile
    check decideAccount(other, "", false, false, true).verdict == cvAdopt
    let missing = group("root", "0", @["repro-no-such-user-7c1e"])
    expect AddonDriftError:
      discard decideAccount(missing, "", false, false, false)

suite "legacy LoadCredential= under the agent's --secrets-dir (§10.3)":
  # Operator decision 2026-10-31: a full-engine agent keeps its
  # --secrets-dir delivery through the switch. The accepting path needs a
  # root-owned directory below /var/lib/repro/agent, which the VM gate
  # e2e_addon_agent_generations_and_rollback provides; here, what is
  # refused, and the checks underneath.
  const Dir = "/var/lib/repro/agent/secrets"
  proc unitWith(line: string): string =
    "[Service]\nExecStart=/bin/true\n" & line & "\n"
  test "everything but a clean source below the directory is refused":
    for bad in ["LoadCredential=x:/run/other/a",
                "LoadCredential=x:" & Dir & "-evil/a",
                "LoadCredential=x:" & Dir & "/../agent/recipient.key",
                "LoadCredential=x:" & Dir,
                "LoadCredential=x:" & Dir & "/%i",
                "LoadCredential=x:" & Dir & "/\\x2e\\x2e/recipient.key",
                "LoadCredential=x:" & Dir & "/a\"b",
                "LoadCredential=x",
                "LoadCredential=x:relative/a"]:
      check rawCredentialDirective(unitWith(bad), [Dir]) == "LoadCredential"
    check rawCredentialDirective(unitWith("LoadCredentialEncrypted=x:" &
      Dir & "/a"), [Dir]) == "LoadCredentialEncrypted"
    check rawCredentialDirective(unitWith("SetCredential=x:y"), [Dir]) ==
      "SetCredential"
    check rawCredentialDirective(unitWith("LoadCredential=x:" & Dir & "/a")) ==
      "LoadCredential"

  test "a path systemd would unescape is not clean (m1 of 49370cf2f2)":
    # At 49370cf2f2 the check was textual and `\x2e\x2e` passed it.
    check legacySecretsPathError(Dir & "/a/\\x2e\\x2e/b").len > 0
    check legacySecretsPathError(Dir & "/a\"b").len > 0
    check legacySecretsPathError(Dir & "/secrets/alertmanager/pushover") == ""

  test "a symlink in the directory that leaves it is refused":
    let tmp = createTempDir("addon-legacy-resolve-", "")
    defer: removeDir(tmp)
    let dir = tmp / "secrets"
    createDir(dir)
    writeFile(dir / "ok", "x")
    writeFile(tmp / "outside", "x")
    createSymlink(tmp / "outside", dir / "leak")
    createSymlink(dir / "ok", dir / "alias")
    check credentialSourceResolvesUnder(dir / "ok", dir)
    # A source that is itself a link is refused, wherever it points, and
    # so is a dangling one. At c3ca271319 both were accepted.
    check not credentialSourceResolvesUnder(dir / "alias", dir)
    createSymlink(dir / "nowhere", dir / "dangling")
    check not credentialSourceResolvesUnder(dir / "dangling", dir)
    check not credentialSourceResolvesUnder(dir / "leak", dir)
    check credentialSourceResolvesUnder(dir / "not-yet", dir)

  test "only a root-owned directory below /var/lib/repro/agent (m2)":
    # At 49370cf2f2 any absolute path registered, and the registry only
    # grew: one `--secrets-dir /etc` widened the accepted sources for good.
    check legacySecretsDirError("/etc").len > 0
    check legacySecretsDirError("/var/lib/repro/agent").len > 0
    check legacySecretsDirError("/var/lib/repro/agent-x/s").len > 0
    check legacySecretsDirError(Dir) == ""
    check legacySecretsTrustError(true, false, 0, 0o40700) == ""
    check legacySecretsTrustError(true, false, 0, 0o40755) == ""
    check legacySecretsTrustError(true, false, 1000, 0o40700).len > 0
    check legacySecretsTrustError(true, false, 0, 0o40770).len > 0
    check legacySecretsTrustError(true, false, 0, 0o40702).len > 0
    check legacySecretsTrustError(true, true, 0, 0o40700).len > 0
    check legacySecretsTrustError(false, false, 0, 0o100600).len > 0
    let tmp = createTempDir("addon-legacy-secrets-", "")
    defer: removeDir(tmp)
    for bad in ["/", "/etc", "relative", Dir & "/", "/var//lib",
                "/var/lib/../x", tmp]:
      expect AgentRecordError:
        registerLegacySecretsDir(tmp, bad)
    # A registry naming an untrusted or foreign directory accepts nothing.
    createDir(tmp / "addon")
    writeFile(legacySecretsDirsPath(tmp), "/etc\n" & tmp & "\n")
    check registeredLegacySecretsDirs(tmp).len == 0
    let prof = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemUnit, address: "systemUnit:a.service",
      suName: "a.service",
      suContent: unitWith("LoadCredential=k:/etc/shadow"))])
    expect EAddOnOutOfScope:
      checkScope(prof, registeredLegacySecretsDirs(tmp))

suite "a unit handed back as found stays running only if nothing changed":
  test "its own bytes, its drop-ins and its dependencies (m4)":
    # At 49370cf2f2 only the unit's own bytes were compared.
    check quietHandBack("s", "s", false, false)
    check not quietHandBack("s", "s", true, false)
    check not quietHandBack("s", "s", false, true)
    check not quietHandBack("s", "t", false, false)
    check not quietHandBack("", "", false, false)

suite "an owned account's update reports the groups it drops":
  test "the live groups the resource does not declare":
    let u = SystemResource(kind: srkPasswdUser, address: "user:nut",
      puName: "nut", puGroups: @["dialout"])
    check droppedSupplementaryGroups(u,
      "dialout:x:20:nut\nplugdev:x:46:pi,nut\naudio:x:29:pi\nnut:x:120:\n") ==
      @["plugdev"]
    check droppedSupplementaryGroups(group("nut"), "x:x:1:nut\n").len == 0

suite "a depends_on naming a timer is a unit dependency (§4.1, §7.3)":
  test "units and timers propagate as units; files do not":
    check isUnitDependency("systemd.systemUnit")
    check isUnitDependency("systemd.systemTimer")
    check not isUnitDependency("fs.systemFile")

suite "a revert keeps a drifted file only as the failed switch found it":
  test "regular, ledger-owned, and the bytes its plan observed (m3)":
    # At 49370cf2f2 any drifted ledger-owned regular file was kept.
    check revertMayKeep("revert", true, true, "s", "s")
    check not revertMayKeep("revert", true, true, "s", "t")
    check not revertMayKeep("revert", true, true, "s", "")
    check not revertMayKeep("revert", false, true, "s", "s")
    check not revertMayKeep("revert", true, false, "s", "s")
    check not revertMayKeep("apply", true, true, "s", "s")
    check not revertMayKeep("rollback", true, true, "s", "s")

suite "the directories above a legacy secrets directory are trusted too":
  test "/var/lib/repro and /var/lib/repro/agent are root-owned, not g/o-writable":
    # At c3ca271319 only the directory itself was checked.
    proc fake(writable: string): LegacyStatFn =
      result = proc(p: string): LegacyStat {.gcsafe.} =
        (true, true, false, 0, (if p == writable: 0o40777 else: 0o40755))
    const Dir = "/var/lib/repro/agent/secrets"
    check legacySecretsDirTrustError(Dir, fake("")) == ""
    for p in ["/var/lib/repro", "/var/lib/repro/agent", Dir]:
      let why = legacySecretsDirTrustError(Dir, fake(p))
      check why.startsWith(p & " ") and "writable" in why
    let deeper = "/var/lib/repro/agent/x/secrets"
    check "/var/lib/repro/agent/x " in
      legacySecretsDirTrustError(deeper, fake("/var/lib/repro/agent/x"))

suite "an untrusted legacy secrets directory is named in the refusal":
  test "the refusal of its lines says which directory and why (m2)":
    # At c3ca271319 the reason went only to a drift line, lost when the
    # scope check refused.
    let prof = SystemProfile(resources: @[SystemResource(
      kind: srkSystemdSystemUnit, address: "systemUnit:a.service",
      suName: "a.service", suContent: "[Service]\nExecStart=/bin/true\n" &
        "LoadCredential=k:/var/lib/repro/agent/secrets/a/k\n")])
    try:
      checkScope(prof, newSeq[string](), ["/var/lib/repro/agent/secrets " &
        "(/var/lib/repro/agent/secrets is group- or world-writable)"])
      check false
    except EAddOnOutOfScope as e:
      check "not accepted as one: /var/lib/repro/agent/secrets " &
        "(/var/lib/repro/agent/secrets is group- or world-writable)" in e.msg

suite "a unit an older closure realiser bound is relocated, not refused":
  test "recognised by its older prefix path alone (§9 Migration)":
    # At 4379adfd3b rpi2's prometheus-node-exporter.service, as its agent
    # wrote it (realiser 2's prefix), was EDrift: none of this existed.
    let r = SystemResource(kind: srkSystemdSystemUnit,
      address: "systemUnit:x.service", suName: "x.service",
      suContent: "[Unit]\nDescription=x\n\n[Service]\nExecStart=/usr/bin/x\n",
      suAptClosureLock: Lock)
    let lock = parseAptClosureLock(Lock)
    let current = aptClosurePrefixPath(AddOnSystemStoreRoot, lock)
    let legacy = legacyAptClosurePrefixPaths(AddOnSystemStoreRoot, lock)
    check legacy.len == 1 and legacy[0] != current
    check legacy[0].startsWith(AddOnSystemStoreRoot & "/prefixes/apt-closure-ipmitool/1.0-1-")
    let rendered = renderedSystemUnitContent(r)
    let old = legacyClosureRenderings(r)
    check old.len == 1 and current notin old[0] and legacy[0] in old[0]
    check old[0] == rendered.replace(current & "/", legacy[0] & "/")
    let tmp = createTempDir("addon-closure-reloc-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "x.service", old[0])
    check relocatesClosure(r, tmp / "x.service")
    writeFile(tmp / "x.service", old[0] & "Nice=5\n")
    check not relocatesClosure(r, tmp / "x.service")
    writeFile(tmp / "x.service", rendered)
    check not relocatesClosure(r, tmp / "x.service")

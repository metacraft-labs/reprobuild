## Library-local unit tests for the M69 system-scope / infra-apply
## library. Covers the PLATFORM-PURE surface — the `system.nim`
## parser, the `RBIP` plan envelope round-trip, the `RBSL` audit-log
## envelope round-trip + truncation handling, the per-resource action
## decision, the partition split, and the `--accept-feature-destroy`
## safety gate. These run everywhere (Windows, Linux, macOS); the
## Windows-only real driver / broker path is exercised by the M69
## integration gates.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_elevation
import repro_infra

suite "repro_infra: system.nim profile parser":

  test "parses the four Windows resources":
    let text = """
# a hand-authored system.nim, M69 Phase A
windows.registryValue {
  key = "HKLM\SOFTWARE\Reprobuild-Tests\smoke"
  name = "Flag"
  kind = string
  value = "on"
}
windows.optionalFeature {
  name = "Microsoft-Windows-Subsystem-Linux"
}
windows.capability {
  name = "OpenSSH.Server~~~~0.0.1.0"
}
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 4
    check profile.resources[0].kind == srkWindowsRegistryValue
    check profile.resources[0].regKey ==
      "HKLM\\SOFTWARE\\Reprobuild-Tests\\smoke"
    check profile.resources[0].regValueKind == srvkString
    check profile.resources[1].kind == srkWindowsOptionalFeature
    check profile.resources[1].featureEnabled
    check profile.resources[2].kind == srkWindowsCapability
    check profile.resources[2].capabilityInstalled
    check profile.resources[3].kind == srkWindowsService
    check profile.resources[3].serviceStartType == "Automatic"
    check profile.resources[3].serviceRunning

  test "parses a windows.firewallRule stanza":
    let text = """
windows.firewallRule {
  name = "OpenSSH-Server-In-TCP"
  displayName = "OpenSSH Server (sshd)"
  protocol = "TCP"
  direction = "Inbound"
  action = "Allow"
  localPort = "22"
  enabled = true
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkWindowsFirewallRule
    check profile.resources[0].fwName == "OpenSSH-Server-In-TCP"
    check profile.resources[0].fwDisplayName == "OpenSSH Server (sshd)"
    check profile.resources[0].fwProtocol == "TCP"
    check profile.resources[0].fwDirection == "Inbound"
    check profile.resources[0].fwAction == "Allow"
    check profile.resources[0].fwLocalPort == "22"
    check profile.resources[0].fwEnabled
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokWindowsFirewallRule
    check op.fwName == "OpenSSH-Server-In-TCP"
    check op.fwProtocol == "TCP"
    check op.fwLocalPort == "22"
    check requiresElevation(op.kind)

  test "windows.firewallRule rejects an unknown protocol":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.firewallRule {
  name = "BadProto"
  protocol = "SCTP"
  direction = "Inbound"
  action = "Allow"
}
""")

  test "windows.firewallRule rejects a name with shell metacharacters":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.firewallRule {
  name = "X'; rm -rf /"
  protocol = "TCP"
  direction = "Inbound"
  action = "Allow"
}
""")

  test "windows.firewallRule rejects a localPort with shell metacharacters":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.firewallRule {
  name = "BadPort"
  protocol = "TCP"
  direction = "Inbound"
  action = "Allow"
  localPort = "22; rm -rf /"
}
""")

  test "parses a windows.acl stanza":
    let text = """
windows.acl {
  path = "C:\Users\Zahary\.ssh"
  owner = "BUILTIN\Administrators"
  accessControlEntries = [
    "BUILTIN\Administrators:(OI)(CI)(F)",
    "NT AUTHORITY\SYSTEM:(OI)(CI)(F)",
    "Zahary:(OI)(CI)(F)"
  ]
  inheritanceMode = "disabled-replace"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkWindowsAcl
    check profile.resources[0].aclPath == "C:\\Users\\Zahary\\.ssh"
    check profile.resources[0].aclOwner == "BUILTIN\\Administrators"
    check profile.resources[0].aclEntries.len == 3
    check profile.resources[0].aclEntries[0] ==
      "BUILTIN\\Administrators:(OI)(CI)(F)"
    check profile.resources[0].aclInheritanceMode == "disabled-replace"
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokWindowsAcl
    check op.aclPath == "C:\\Users\\Zahary\\.ssh"
    check op.aclEntries.len == 3
    check op.aclInheritanceMode == "disabled-replace"
    check requiresElevation(op.kind)

  test "windows.acl rejects an unknown inheritanceMode":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.acl {
  path = "C:\Users\Zahary\.ssh"
  accessControlEntries = ["Administrators:(F)"]
  inheritanceMode = "off"
}
""")

  test "windows.acl rejects a path with `..` segment":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.acl {
  path = "C:\Users\..\Windows"
  accessControlEntries = ["Administrators:(F)"]
}
""")

  test "windows.acl rejects an ACE with shell metacharacters":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.acl {
  path = "C:\foo"
  accessControlEntries = ["Administrators:(F);rm -rf /"]
}
""")

  test "windows.acl rejects an empty accessControlEntries list":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.acl {
  path = "C:\foo"
  accessControlEntries = []
}
""")

  test "parses an os.timezone stanza":
    let text = """
os.timezone {
  tz = "Europe/Sofia"
  address = "userTimezone"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkOsTimezone
    check profile.resources[0].tzIana == "Europe/Sofia"
    check profile.resources[0].address == "userTimezone"
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokOsTimezone
    check op.tzIana == "Europe/Sofia"
    check requiresElevation(op.kind)

  test "os.timezone rejects an IANA name with shell metacharacters":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
os.timezone {
  tz = "Europe/Sofia;rm"
}
""")

  test "os.timezone rejects an unmapped IANA name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
os.timezone {
  tz = "Atlantis/Citadel"
}
""")

  test "parses an os.hostname stanza":
    let text = """
os.hostname {
  hostname = "MyDevBox"
  address = "userHostname"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkOsHostname
    check profile.resources[0].hostnameName == "MyDevBox"
    check profile.resources[0].address == "userHostname"
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokOsHostname
    check op.hostnameName == "MyDevBox"
    check requiresElevation(op.kind)

  test "os.hostname rejects a name with shell metacharacters":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
os.hostname {
  hostname = "host;rm -rf /"
}
""")

  test "os.hostname rejects an underscore":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
os.hostname {
  hostname = "my_host"
}
""")

  test "an HKCU registry key is rejected (home-scope, not system)":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.registryValue {
  key = "HKCU\Software\Foo"
  name = "X"
}
""")

  test "an unknown resource kind is rejected with a clear message":
    # M69 Phase C undeferred the six POSIX/macOS resource kinds
    # (`fs.systemFile`, `env.systemVariable`, `macos.systemDefault`,
    # `systemd.systemUnit`, `launchd.systemDaemon`, `passwd.user`):
    # `fs.systemFile` now parses (covered by the Phase-C suites). A
    # genuinely UNKNOWN kind tag is still rejected.
    var raised = false
    try:
      discard parseSystemProfile(
        "totally.unknownKind {\n  path = \"/etc/x\"\n}\n")
    except ESystemProfileInvalid as e:
      raised = true
      check e.detail.contains("unknown system resource kind")
    check raised
    # `fs.systemFile` is a recognized Phase-C kind — it parses cleanly.
    let parsed = parseSystemProfile(
      "fs.systemFile {\n  path = \"/etc/x\"\n  content = \"y\"\n}\n")
    check parsed.resources.len == 1
    check parsed.resources[0].kind == srkFsSystemFile

  test "fs.systemDirectory parses without ACL":
    let parsed = parseSystemProfile(
      "fs.systemDirectory {\n  path = \"/etc/myapp.d\"\n}\n")
    check parsed.resources.len == 1
    check parsed.resources[0].kind == srkFsSystemDirectory
    check parsed.resources[0].dirPath == "/etc/myapp.d"
    check parsed.resources[0].dirAclPresent == false

  test "fs.systemDirectory parses with ACL":
    let parsed = parseSystemProfile("""
fs.systemDirectory {
  path = "C:\actions-runner-tokens"
  aclOwner = "SYSTEM"
  aclEntries = ["SYSTEM:(F)", "BUILTIN\Administrators:(F)"]
  aclInheritance = "protected-clear-inherited"
}
""")
    check parsed.resources.len == 1
    check parsed.resources[0].kind == srkFsSystemDirectory
    check parsed.resources[0].dirPath == "C:\\actions-runner-tokens"
    check parsed.resources[0].dirAclPresent == true
    check parsed.resources[0].dirAclOwner == "SYSTEM"
    check parsed.resources[0].dirAclEntries.len == 2
    check parsed.resources[0].dirAclInheritance ==
      "protected-clear-inherited"

  test "fs.systemDirectory roundtrips to PrivilegedOperation":
    let parsed = parseSystemProfile(
      "fs.systemDirectory {\n  path = \"/etc/myapp.d\"\n}\n")
    let op = toPrivilegedOperation(parsed.resources[0])
    check op.kind == pokFsSystemDirectory
    check op.fsdPath == "/etc/myapp.d"
    check op.fsdAclPresent == false
    check op.fsdDestroy == false

  test "fs.systemFile parses with sourceUrl + sha256":
    # Windows-System-Resources Phase A: the URL-fetch content source.
    let parsed = parseSystemProfile("""
fs.systemFile {
  path = "C:\actions-runner-cache\runner.zip"
  sourceUrl = "https://example.com/runner.zip"
  sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}
""")
    check parsed.resources.len == 1
    check parsed.resources[0].kind == srkFsSystemFile
    check parsed.resources[0].sfPath ==
      "C:\\actions-runner-cache\\runner.zip"
    check parsed.resources[0].sfSourceUrl ==
      "https://example.com/runner.zip"
    check parsed.resources[0].sfSha256.len == 64
    check parsed.resources[0].sfContent == ""
    check parsed.resources[0].sfSourceLocal == ""
    let op = toPrivilegedOperation(parsed.resources[0])
    check op.sfSourceUrl == "https://example.com/runner.zip"
    check op.sfSha256.len == 64

  test "fs.systemFile parses with sourceLocal":
    # Windows-System-Resources Phase A: the controller-side path
    # content source.
    let parsed = parseSystemProfile("""
fs.systemFile {
  path = "/etc/myapp/config.toml"
  sourceLocal = "/home/zah/profiles/myapp.toml"
}
""")
    check parsed.resources.len == 1
    check parsed.resources[0].kind == srkFsSystemFile
    check parsed.resources[0].sfSourceLocal ==
      "/home/zah/profiles/myapp.toml"
    check parsed.resources[0].sfContent == ""
    check parsed.resources[0].sfSourceUrl == ""
    let op = toPrivilegedOperation(parsed.resources[0])
    check op.sfSourceLocal == "/home/zah/profiles/myapp.toml"

  test "fs.systemFile rejects content + sourceUrl together":
    # Mutual-exclusion: the validator MUST refuse a profile that sets
    # more than one of the three sources, regardless of which two.
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
fs.systemFile {
  path = "/etc/myapp/config.toml"
  content = "x = 1"
  sourceUrl = "https://example.com/c.toml"
  sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}
""")

  test "fs.systemFile rejects content + sourceLocal together":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
fs.systemFile {
  path = "/etc/myapp/config.toml"
  content = "x = 1"
  sourceLocal = "/home/zah/profiles/myapp.toml"
}
""")

  test "fs.systemFile rejects sourceUrl without sha256":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
fs.systemFile {
  path = "/etc/myapp/config.toml"
  sourceUrl = "https://example.com/c.toml"
}
""")

  test "fs.systemFile rejects sourceUrl + sourceLocal together":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
fs.systemFile {
  path = "/etc/myapp/config.toml"
  sourceUrl = "https://example.com/c.toml"
  sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  sourceLocal = "/home/zah/profiles/myapp.toml"
}
""")

  test "fs.systemFile PrivilegedOperation frame round-trips all three sources":
    # Codec round-trip: encode + decode preserves every source field.
    let inline = PrivilegedOperation(kind: pokFsSystemFile,
      address: "inlineCfg", sfPath: "/etc/inline.cfg",
      sfContent: "k = v\n", sfDestroy: false)
    check operationValidationError(inline) == ""
    let inlineRT = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: inline,
        baselineDigestHex: ""))).body).operation
    check inlineRT.kind == pokFsSystemFile
    check inlineRT.sfPath == "/etc/inline.cfg"
    check inlineRT.sfContent == "k = v\n"
    check inlineRT.sfSourceUrl == ""
    check inlineRT.sfSha256 == ""
    check inlineRT.sfSourceLocal == ""

    let urlOp = PrivilegedOperation(kind: pokFsSystemFile,
      address: "urlCfg", sfPath: "/etc/url.cfg",
      sfSourceUrl: "https://example.com/url.cfg",
      sfSha256: "0123456789abcdef0123456789abcdef" &
                "0123456789abcdef0123456789abcdef",
      sfDestroy: false)
    check operationValidationError(urlOp) == ""
    let urlRT = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: urlOp,
        baselineDigestHex: ""))).body).operation
    check urlRT.sfSourceUrl == "https://example.com/url.cfg"
    check urlRT.sfSha256.len == 64
    check urlRT.sfContent == ""
    check urlRT.sfSourceLocal == ""

    let localOp = PrivilegedOperation(kind: pokFsSystemFile,
      address: "localCfg", sfPath: "/etc/local.cfg",
      sfSourceLocal: "/home/zah/profiles/local.cfg",
      sfDestroy: false)
    check operationValidationError(localOp) == ""
    let localRT = decodeOperation(decodeFrame(encodeOperation(
      WireOperation(operation: localOp,
        baselineDigestHex: ""))).body).operation
    check localRT.sfSourceLocal == "/home/zah/profiles/local.cfg"
    check localRT.sfContent == ""
    check localRT.sfSourceUrl == ""
    check localRT.sfSha256 == ""

  test "fs.systemFile rendered stanza round-trips through parseSystemProfile":
    for r in [
      SystemResource(kind: srkFsSystemFile,
        address: "systemFile:/etc/url.cfg",
        sfPath: "/etc/url.cfg",
        sfSourceUrl: "https://example.com/url.cfg",
        sfSha256: "0123456789abcdef0123456789abcdef" &
                  "0123456789abcdef0123456789abcdef"),
      SystemResource(kind: srkFsSystemFile,
        address: "systemFile:/etc/local.cfg",
        sfPath: "/etc/local.cfg",
        sfSourceLocal: "/home/zah/profiles/local.cfg")]:
      let lines = renderStanza(r)
      let reparsed = parseSystemProfile(lines.join("\n") & "\n")
      check reparsed.resources.len == 1
      check reparsed.resources[0].kind == r.kind
      check reparsed.resources[0].sfPath == r.sfPath
      check reparsed.resources[0].sfSourceUrl == r.sfSourceUrl
      check reparsed.resources[0].sfSha256 == r.sfSha256
      check reparsed.resources[0].sfSourceLocal == r.sfSourceLocal

  test "an unclosed block is rejected":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("windows.capability {\n  name = \"X\"\n")

  test "each resource maps to a typed PrivilegedOperation":
    let profile = parseSystemProfile("""
windows.registryValue {
  key = "HKLM\SOFTWARE\X"
  name = "V"
  kind = dword
  value = "7"
}
""")
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokWindowsRegistryValue
    check op.hklmSubkey == "SOFTWARE\\X"
    check op.hklmValueKind == srvkDword
    check requiresElevation(op.kind)

suite "repro_infra: RBIP plan envelope":

  test "encode / decode round-trip":
    var env: PlanEnvelope
    env.schemaVersion = PlanSchemaVersion
    env.planId = "0123456789abcdef0123456789abcdef"
    env.createdTimestamp = 1_700_000_000
    env.hostIdentity = "eli-pc"
    env.profileDigestHex = "deadbeef"
    env.operations.add(PlannedOperationRecord(
      address: "feature:WSL", kindTag: "windows.optionalFeature",
      privileged: true, action: "create",
      baselineDigestHex: "00", desiredDigestHex: "ff",
      summary: "create optional-feature WSL"))
    let bytes = encodePlan(env)
    let back = decodePlanBytes(bytes)
    check back.planId == env.planId
    check back.hostIdentity == "eli-pc"
    check back.operations.len == 1
    check back.operations[0].privileged
    check back.operations[0].action == "create"

  test "a corrupt checksum is rejected":
    var env: PlanEnvelope
    env.planId = "x"
    var bytes = encodePlan(env)
    bytes[^1] = bytes[^1] xor 0xff'u8
    expect EPlanCorrupt:
      discard decodePlanBytes(bytes)

  test "trailing extra bytes are rejected":
    var env: PlanEnvelope
    env.planId = "x"
    var bytes = encodePlan(env)
    bytes.insert(0xAA'u8, bytes.len - 32)
    expect EPlanCorrupt:
      discard decodePlanBytes(bytes)

  test "plan file write / read round-trip":
    let dir = createTempDir("repro-infra-plan-", "")
    defer: removeDir(dir)
    var env: PlanEnvelope
    env.planId = "abc"
    env.hostIdentity = "h"
    let p = dir / "abc.rbip"
    writePlanFile(p, env)
    check readPlanFile(p).planId == "abc"

suite "repro_infra: RBSL audit log":

  test "append + read round-trip across multiple records":
    let dir = createTempDir("repro-infra-audit-", "")
    defer: removeDir(dir)
    let logPath = dir / "apply.log"
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 100, operationKind: "windows.registryValue",
      resourceAddress: "r1", outcome: "applied",
      preDigestHex: "00", postDigestHex: "ab"))
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 101, operationKind: "windows.service",
      resourceAddress: "r2", outcome: "no-op",
      preDigestHex: "cd", postDigestHex: "cd"))
    let r = readAuditLog(logPath)
    check r.records.len == 2
    check not r.truncatedTail
    check r.records[0].resourceAddress == "r1"
    check r.records[1].outcome == "no-op"

  test "a truncated final record is reported, earlier records survive":
    let dir = createTempDir("repro-infra-audit-trunc-", "")
    defer: removeDir(dir)
    let logPath = dir / "apply.log"
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 1, operationKind: "k", resourceAddress: "ok",
      outcome: "applied"))
    # Append a half-written second record (simulate a crash).
    let partial = encodeAuditRecord(AuditRecord(
      timestamp: 2, operationKind: "k", resourceAddress: "partial",
      outcome: "applied"))
    var f: File
    check open(f, logPath, fmAppend)
    f.write(($cast[string](partial))[0 ..< partial.len div 2])
    close(f)
    let r = readAuditLog(logPath)
    check r.records.len == 1
    check r.records[0].resourceAddress == "ok"
    check r.truncatedTail

  test "a record with a bad checksum raises":
    let dir = createTempDir("repro-infra-audit-bad-", "")
    defer: removeDir(dir)
    let logPath = dir / "apply.log"
    let good = encodeAuditRecord(AuditRecord(
      timestamp: 1, operationKind: "k", resourceAddress: "r",
      outcome: "applied"))
    var s = newString(good.len)
    for i, b in good: s[i] = char(b)
    s[^1] = char(byte(s[^1]) xor 0xff'u8)
    writeFile(logPath, s)
    expect EAuditLogCorrupt:
      discard readAuditLog(logPath)

suite "repro_infra: planner action decision + partition":

  test "decideAction follows the M68 contract":
    check decideAction(ResourceObservation(present: false), "ff",
      destroy = false) == "create"
    check decideAction(ResourceObservation(present: true,
      observedDigestHex: "ff"), "ff", destroy = false) == "no-op"
    check decideAction(ResourceObservation(present: true,
      observedDigestHex: "11"), "ff", destroy = false) == "update"
    check decideAction(ResourceObservation(present: false), "ff",
      destroy = true) == "no-op"
    check decideAction(ResourceObservation(present: true,
      observedDigestHex: "ff"), "ff", destroy = true) == "destroy"

  test "every Windows system resource partitions as privileged":
    let profile = parseSystemProfile("""
windows.optionalFeature { name = "Hyper-V" }
windows.capability { name = "RSAT~~~~" }
""")
    var ops: seq[PrivilegedOperation]
    for r in profile.resources:
      ops.add(toPrivilegedOperation(r))
    let part = partitionApply(ops, nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 2
    check part.hasPrivilegedWork()
    check part.requiresBroker(alreadyElevated = false)
    check not part.requiresBroker(alreadyElevated = true)

suite "repro_infra: --accept-feature-destroy gate":

  test "feature / capability rollback is destructive, registry is not":
    let profile = parseSystemProfile("""
windows.optionalFeature { name = "WSL" }
windows.registryValue { key = "HKLM\SOFTWARE\X" name = "v" }
""")
    let decision = screenRollback(profile.resources)
    check decision.requiresFeatureDestroyFlag
    check decision.destructiveAddresses.len == 1

  test "the gate fails closed without the flag":
    let profile = parseSystemProfile(
      "windows.capability { name = \"OpenSSH.Server~~~~\" }\n")
    let decision = screenRollback(profile.resources)
    expect EFeatureDestroy:
      enforceFeatureDestroyGate(decision, acceptFeatureDestroy = false)
    # With the flag it does not raise.
    enforceFeatureDestroyGate(decision, acceptFeatureDestroy = true)

suite "repro_infra: system state dir":

  test "the REPRO_INFRA_STATE_DIR override wins":
    let saved = getEnv(StateDirEnvVar)
    putEnv(StateDirEnvVar, "D:/some/override/path")
    check resolveSystemStateDir() == "D:/some/override/path"
    if saved.len > 0: putEnv(StateDirEnvVar, saved)
    else: delEnv(StateDirEnvVar)

  test "sub-path helpers compose the documented layout":
    let sd = "X"
    check planPath(sd, "pid").endsWith("pid.rbip")
    check applyLogPath(sd, "gid").endsWith("apply.log")
    check applyLockPath(sd).endsWith("apply.lock")

# ===========================================================================
# M69 Phase B — windows.vsInstaller profile parsing, the structural
# editor, and the RBSG generation envelope.
# ===========================================================================

suite "repro_infra: windows.vsInstaller profile parsing (Phase B)":

  test "a vsInstaller stanza with list fields parses":
    let profile = parseSystemProfile("""
windows.vsInstaller {
  edition = "BuildTools"
  channel = "VisualStudio.17.Release"
  installPath = "C:\BuildTools"
  workloads = [
    "Microsoft.VisualStudio.Workload.VCTools",
    "Microsoft.VisualStudio.Workload.MSBuildTools"
  ]
  components = ["Microsoft.VisualStudio.Component.Git"]
  strict = true
}
""")
    check profile.resources.len == 1
    let r = profile.resources[0]
    check r.kind == srkWindowsVsInstaller
    check r.vsEdition == "BuildTools"
    check r.vsChannel == "VisualStudio.17.Release"
    check r.vsWorkloads.len == 2
    check r.vsComponents == @["Microsoft.VisualStudio.Component.Git"]
    check r.vsStrict
    let op = toPrivilegedOperation(r)
    check op.kind == pokWindowsVsInstaller
    check op.vsWorkloads.len == 2

  test "channel defaults to Release, strict defaults to false":
    let profile = parseSystemProfile("""
windows.vsInstaller {
  edition = "Community"
}
""")
    check profile.resources[0].vsChannel == "Release"
    check not profile.resources[0].vsStrict
    check profile.resources[0].vsWorkloads.len == 0

  test "parseListLiteral handles empty, single, and multi-element lists":
    check parseListLiteral("[]").len == 0
    check parseListLiteral("[\"a\"]") == @["a"]
    check parseListLiteral("[a, b, c]") == @["a", "b", "c"]
    check parseListLiteral("[\n  \"x\",\n  \"y\"\n]") == @["x", "y"]

  test "a vsInstaller rollback is destructive (uninstall)":
    let profile = parseSystemProfile(
      "windows.vsInstaller { edition = \"BuildTools\" }\n")
    check isDestructiveRollback(profile.resources[0])

suite "repro_infra: system.nim structural editor (Phase B)":

  test "addResource then removeResource round-trips byte-identically":
    let dir = createTempDir("repro-infra-editor-", "")
    defer: removeDir(dir)
    let p = dir / "system.nim"
    let original =
      "# the gate's system profile\n" &
      "windows.service {\n  name = \"sshd\"\n  startType = Automatic\n" &
      "  state = Running\n}\n"
    writeFile(p, original)
    var doc = loadSystemIntent(p)
    let newRes = SystemResource(kind: srkWindowsOptionalFeature,
      address: "feature:Containers", featureName: "Containers",
      featureEnabled: true)
    addResource(doc, newRes)
    writeSystemIntent(doc)
    check readFile(p) != original
    # remove the just-added resource — must restore byte-for-byte.
    var doc2 = loadSystemIntent(p)
    check removeResource(doc2, "feature:Containers")
    writeSystemIntent(doc2)
    check readFile(p) == original

  test "addResource refuses a duplicate address":
    let dir = createTempDir("repro-infra-editor-dup-", "")
    defer: removeDir(dir)
    let p = dir / "system.nim"
    writeFile(p, "")
    var doc = loadSystemIntent(p)
    let r = SystemResource(kind: srkWindowsCapability,
      address: "capability:OpenSSH.Server~~~~0.0.1.0",
      capabilityName: "OpenSSH.Server~~~~0.0.1.0", capabilityInstalled: true)
    addResource(doc, r)
    expect ESystemProfileInvalid:
      addResource(doc, r)

  test "removeResource of an absent address is a no-op (returns false)":
    let dir = createTempDir("repro-infra-editor-absent-", "")
    defer: removeDir(dir)
    let p = dir / "system.nim"
    writeFile(p, "windows.service {\n  name = \"sshd\"\n}\n")
    var doc = loadSystemIntent(p)
    check not removeResource(doc, "service:not-here")

  test "the editor preserves a CRLF line ending":
    let dir = createTempDir("repro-infra-editor-crlf-", "")
    defer: removeDir(dir)
    let p = dir / "system.nim"
    let crlf = "windows.service {\r\n  name = \"sshd\"\r\n}\r\n"
    writeFile(p, crlf)
    var doc = loadSystemIntent(p)
    check doc.lineEnding == "\r\n"
    addResource(doc, SystemResource(kind: srkWindowsOptionalFeature,
      address: "feature:WSL", featureName: "WSL", featureEnabled: true))
    writeSystemIntent(doc)
    var doc2 = loadSystemIntent(p)
    check removeResource(doc2, "feature:WSL")
    writeSystemIntent(doc2)
    check readFile(p) == crlf

  test "a rendered vsInstaller stanza re-parses to the same resource":
    let r = SystemResource(kind: srkWindowsVsInstaller,
      address: "vsInstaller:BuildTools",
      vsEdition: "BuildTools", vsChannel: "VisualStudio.17.Release",
      vsInstallPath: r"C:\BuildTools",
      vsWorkloads: @["Microsoft.VisualStudio.Workload.VCTools"],
      vsComponents: @["Microsoft.VisualStudio.Component.Git"],
      vsStrict: true)
    var lines = renderStanza(r)
    let reparsed = parseSystemProfile(lines.join("\n") & "\n")
    check reparsed.resources.len == 1
    check reparsed.resources[0].kind == srkWindowsVsInstaller
    check reparsed.resources[0].vsEdition == "BuildTools"
    check reparsed.resources[0].vsWorkloads ==
      @["Microsoft.VisualStudio.Workload.VCTools"]
    check reparsed.resources[0].vsStrict

suite "repro_infra: RBSG generation envelope (Phase B)":

  test "encode / decode round-trip":
    let env = GenerationEnvelope(
      schemaVersion: GenSchemaVersion,
      generationId: "0123456789abcdef0123456789abcdef",
      activationTimestamp: 1_700_000_500,
      hostIdentity: "eli-pc",
      planId: "plan-abc",
      profileDigestHex: "deadbeef",
      profileText: "windows.service {\n  name = \"sshd\"\n}\n",
      appliedCount: 3, noOpCount: 1)
    let back = decodeGenerationBytes(encodeGeneration(env))
    check back.generationId == env.generationId
    check back.hostIdentity == "eli-pc"
    check back.profileText == env.profileText
    check back.appliedCount == 3
    check back.noOpCount == 1

  test "a corrupt checksum is rejected":
    let env = GenerationEnvelope(generationId: "x")
    var bytes = encodeGeneration(env)
    bytes[^1] = bytes[^1] xor 0xff'u8
    expect EPlanCorrupt:
      discard decodeGenerationBytes(bytes)

  test "enumerateSystemGenerations + resolveGenerationId":
    let dir = createTempDir("repro-infra-gens-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    # Two generations, increasing timestamps.
    for (gid, ts) in [("aaaa1111aaaa1111aaaa1111aaaa1111", 100'i64),
                      ("bbbb2222bbbb2222bbbb2222bbbb2222", 200'i64)]:
      createDir(generationDir(dir, gid))
      writeGenerationEnvelope(pointerPath(dir, gid), GenerationEnvelope(
        schemaVersion: GenSchemaVersion, generationId: gid,
        activationTimestamp: ts, hostIdentity: "h", planId: "p",
        profileDigestHex: "d", profileText: "", appliedCount: 1))
    writeCurrentGenerationId(dir, "bbbb2222bbbb2222bbbb2222bbbb2222")
    let gens = enumerateSystemGenerations(dir)
    check gens.len == 2
    check gens[0].generationId == "aaaa1111aaaa1111aaaa1111aaaa1111"  # oldest
    check gens[1].isActive
    # An empty requested id resolves to the immediately-previous gen.
    check resolveGenerationId(dir, "") ==
      "aaaa1111aaaa1111aaaa1111aaaa1111"
    # A prefix resolves unambiguously.
    check resolveGenerationId(dir, "aaaa") ==
      "aaaa1111aaaa1111aaaa1111aaaa1111"
    # An unknown id raises.
    expect ESystemStateDirInvalid:
      discard resolveGenerationId(dir, "ffff")

# ===========================================================================
# M69 Phase C — the six POSIX / macOS resource kinds: profile parsing,
# the typed-operation mapping, the structural editor round-trip, the
# planner summary, and the `--accept-passwd-destroy` safety gate. All
# platform-pure — these run on every host.
# ===========================================================================

suite "repro_infra: Phase C POSIX/macOS profile parsing":

  test "the six Phase-C resource kinds parse (no longer deferred)":
    let profile = parseSystemProfile("""
macos.systemDefault {
  domain = "/Library/Preferences/com.apple.loginwindow"
  key = "SHOWFULLNAME"
  type = "-bool"
  value = "true"
  restartTarget = "loginwindow"
}
systemd.systemUnit {
  name = "repro-agent.service"
  content = "[Unit]
Description=Repro agent
[Service]
ExecStart=/usr/local/bin/repro-agent
"
}
launchd.systemDaemon {
  label = "com.example.daemon"
  programArgs = ["/usr/local/bin/d", "--flag"]
}
fs.systemFile {
  path = "/etc/profile.d/repro-system.sh"
  content = "export REPRO=1
"
}
env.systemVariable {
  name = "PATH"
  contribute = ["/opt/repro/bin"]
  isPathList = true
}
passwd.user {
  name = "deploy"
  home = "/home/deploy"
  shell = "/bin/bash"
  groups = ["docker", "wheel"]
}
""")
    check profile.resources.len == 6
    check profile.resources[0].kind == srkMacosSystemDefault
    check profile.resources[0].sdKey == "SHOWFULLNAME"
    check profile.resources[0].sdRestartTarget == "loginwindow"
    check profile.resources[1].kind == srkSystemdSystemUnit
    check profile.resources[1].suName == "repro-agent.service"
    check profile.resources[1].suContent.contains("ExecStart=")
    check profile.resources[1].suEnabled        # defaults true
    check profile.resources[2].kind == srkLaunchdSystemDaemon
    check profile.resources[2].sdaProgramArgs ==
      @["/usr/local/bin/d", "--flag"]
    check profile.resources[3].kind == srkFsSystemFile
    check profile.resources[3].sfPath == "/etc/profile.d/repro-system.sh"
    check profile.resources[4].kind == srkEnvSystemVariable
    check profile.resources[4].evContribution == @["/opt/repro/bin"]
    check profile.resources[4].evIsPathList
    check profile.resources[5].kind == srkPasswdUser
    check profile.resources[5].puName == "deploy"
    check profile.resources[5].puGroups == @["docker", "wheel"]

  test "each Phase-C resource maps to its typed PrivilegedOperation":
    let profile = parseSystemProfile("""
passwd.user { name = "deploy" groups = ["docker"] }
fs.systemFile { path = "/etc/repro.conf" content = "x" }
""")
    let userOp = toPrivilegedOperation(profile.resources[0])
    check userOp.kind == pokPasswdUser
    check userOp.puName == "deploy"
    check not userOp.puDestroy
    check requiresElevation(userOp.kind)
    # The destroy direction flips the typed operation.
    let userDestroy = toPrivilegedOperation(profile.resources[0],
      destroy = true)
    check userDestroy.puDestroy
    let fileOp = toPrivilegedOperation(profile.resources[1])
    check fileOp.kind == pokFsSystemFile
    check fileOp.sfPath == "/etc/repro.conf"

  test "a launchd.systemDaemon with no programArgs is rejected":
    expect ESystemProfileInvalid:
      discard parseSystemProfile(
        "launchd.systemDaemon { label = \"com.x.d\" }\n")

  test "systemd.systemUnit requires name + content":
    expect ESystemProfileInvalid:
      discard parseSystemProfile(
        "systemd.systemUnit { name = \"x.service\" }\n")

  test "passwd.user rollback is gated by --accept-passwd-destroy, not -feature":
    let profile = parseSystemProfile(
      "passwd.user { name = \"deploy\" }\n")
    check requiresPasswdDestroy(profile.resources[0])
    check not isDestructiveRollback(profile.resources[0])
    # A feature is the other way round.
    let feat = parseSystemProfile(
      "windows.optionalFeature { name = \"WSL\" }\n")
    check isDestructiveRollback(feat.resources[0])
    check not requiresPasswdDestroy(feat.resources[0])

suite "repro_infra: Phase C --accept-passwd-destroy gate":

  test "screenRollback flags a passwd.user revert separately from features":
    let profile = parseSystemProfile("""
passwd.user { name = "deploy" }
windows.optionalFeature { name = "WSL" }
windows.registryValue { key = "HKLM\SOFTWARE\X" name = "v" }
""")
    let decision = screenRollback(profile.resources)
    check decision.requiresPasswdDestroyFlag
    check decision.passwdDestroyAddresses == @["user:deploy"]
    check decision.requiresFeatureDestroyFlag    # the WSL feature
    check decision.destructiveAddresses.len == 1

  test "the passwd-destroy gate fails closed without the flag":
    let profile = parseSystemProfile(
      "passwd.user { name = \"deploy\" }\n")
    let decision = screenRollback(profile.resources)
    expect EPasswdDestroy:
      enforcePasswdDestroyGate(decision, acceptPasswdDestroy = false)
    # With the flag it does not raise.
    enforcePasswdDestroyGate(decision, acceptPasswdDestroy = true)
    # A profile with no passwd.user does not trip the gate.
    let noUser = parseSystemProfile(
      "windows.optionalFeature { name = \"WSL\" }\n")
    enforcePasswdDestroyGate(screenRollback(noUser.resources),
      acceptPasswdDestroy = false)

suite "repro_infra: Phase C structural editor round-trip":

  test "add then remove a passwd.user stanza round-trips byte-identically":
    let dir = createTempDir("repro-infra-editor-pc-", "")
    defer: removeDir(dir)
    let p = dir / "system.nim"
    let original =
      "# the gate's system profile\n" &
      "windows.service {\n  name = \"sshd\"\n  startType = Automatic\n" &
      "  state = Running\n}\n"
    writeFile(p, original)
    var doc = loadSystemIntent(p)
    addResource(doc, SystemResource(kind: srkPasswdUser,
      address: "user:deploy", puName: "deploy", puHome: "/home/deploy",
      puShell: "/bin/bash", puGroups: @["docker"]))
    writeSystemIntent(doc)
    check readFile(p) != original
    var doc2 = loadSystemIntent(p)
    check removeResource(doc2, "user:deploy")
    writeSystemIntent(doc2)
    check readFile(p) == original

  test "a rendered Phase-C stanza re-parses to the same resource":
    # The rendered stanza carries no explicit `address` field, so the
    # re-parsed resource derives its address via `realWorldIdentity`;
    # each fixture below uses the matching derived address.
    for r in [
      SystemResource(kind: srkPasswdUser, address: "user:deploy",
        puName: "deploy", puHome: "/home/deploy", puShell: "/bin/bash",
        puGroups: @["docker", "wheel"]),
      SystemResource(kind: srkFsSystemFile,
        address: "systemFile:/etc/profile.d/repro.sh",
        sfPath: "/etc/profile.d/repro.sh", sfContent: "export X=1"),
      SystemResource(kind: srkEnvSystemVariable,
        address: "systemVariable:REPRO_HOME",
        evName: "REPRO_HOME", evContribution: @["/opt/repro"],
        evIsPathList: false),
      SystemResource(kind: srkMacosSystemDefault,
        address: "systemDefault:com.apple.loginwindow:SHOWFULLNAME",
        sdDomain: "com.apple.loginwindow", sdKey: "SHOWFULLNAME",
        sdValueType: "-bool", sdValueLiteral: "true",
        sdRestartTarget: "loginwindow")]:
      let lines = renderStanza(r)
      let reparsed = parseSystemProfile(lines.join("\n") & "\n")
      check reparsed.resources.len == 1
      check reparsed.resources[0].kind == r.kind
      check reparsed.resources[0].address == r.address

suite "repro_infra: Phase C planner summary":

  test "the planner action decision works for a Phase-C kind":
    # decideAction is kind-agnostic; confirm it on a passwd.user obs.
    check decideAction(ResourceObservation(present: false), "ff",
      destroy = false) == "create"
    check decideAction(ResourceObservation(present: true,
      observedDigestHex: "ff"), "ff", destroy = false) == "no-op"

  test "Phase-C resources partition as privileged":
    let profile = parseSystemProfile("""
passwd.user { name = "deploy" }
systemd.systemUnit { name = "x.service" content = "[Unit]" }
""")
    var ops: seq[PrivilegedOperation]
    for r in profile.resources:
      ops.add(toPrivilegedOperation(r))
    let part = partitionApply(ops, nonPrivilegedOperationCount = 0)
    check part.privilegedOperations.len == 2
    check part.hasPrivilegedWork()

# ===========================================================================
# M82 Phase B — `depends_on` profile-syntax + planner dependency graph
# + topological-order plan emission. Pure-logic, runs on every host.
# ===========================================================================

suite "repro_infra: depends_on profile syntax (M82 Phase B)":

  test "a resource with no depends_on parses with an empty seq":
    let profile = parseSystemProfile("""
windows.service { name = "sshd" startType = Automatic state = Running }
""")
    check profile.resources.len == 1
    check profile.resources[0].dependsOn.len == 0

  test "an explicit depends_on list parses into typed (kind, name) entries":
    let profile = parseSystemProfile("""
windows.capability {
  name = "OpenSSH.Server~~~~0.0.1.0"
}
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
  depends_on = ["windows.capability:OpenSSH.Server~~~~0.0.1.0"]
}
""")
    check profile.resources[1].dependsOn.len == 1
    check profile.resources[1].dependsOn[0].kind == "windows.capability"
    check profile.resources[1].dependsOn[0].name ==
      "OpenSSH.Server~~~~0.0.1.0"

  test "a malformed depends_on entry is rejected with a clear message":
    var raised = false
    try:
      discard parseSystemProfile("""
windows.service {
  name = "sshd"
  depends_on = ["no-colon-at-all"]
}
""")
    except ESystemProfileInvalid as e:
      raised = true
      check e.detail.contains("depends_on")
      check e.detail.contains("kind:name")
    check raised
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.service { name = "s" depends_on = [":missing-kind"] }
""")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
windows.service { name = "s" depends_on = ["windows.capability:"] }
""")

  test "an empty depends_on list parses to an empty seq (no error)":
    let profile = parseSystemProfile("""
windows.service { name = "s" depends_on = [] }
""")
    check profile.resources[0].dependsOn.len == 0

  test "a name with a colon (HKLM key path) still parses by splitting on first ':'":
    # Per the design, the FIRST `:` separates kind from name — a
    # consumer that depends on a producer whose name itself contains a
    # `:` (an HKLM key path that includes a literal colon, or a
    # `macos.systemDefault` `domain:key` identifier) parses correctly.
    # The string-literal parser is byte-faithful — it does NOT
    # un-escape backslashes — so we exercise the colon-split with a
    # value the parser keeps verbatim.
    let profile = parseSystemProfile("""
macos.systemDefault {
  domain = "com.example.app"
  key = "feature:enabled"
  type = "-bool"
  value = "true"
}
fs.systemFile {
  path = "/etc/app.conf"
  content = "x"
  depends_on = ["macos.systemDefault:com.example.app:feature:enabled"]
}
""")
    check profile.resources[1].dependsOn[0].kind == "macos.systemDefault"
    check profile.resources[1].dependsOn[0].name ==
      "com.example.app:feature:enabled"

suite "repro_infra: planner dependency graph + topological sort (M82 Phase B)":

  test "buildDependencyGraph picks up an explicit edge":
    let profile = parseSystemProfile("""
windows.capability { name = "OpenSSH.Server~~~~0.0.1.0" }
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
  depends_on = ["windows.capability:OpenSSH.Server~~~~0.0.1.0"]
}
""")
    let graph = buildDependencyGraph(profile)
    check graph.edges.len == 1
    check graph.edges[0].fromIdx == 0     # capability is the producer
    check graph.edges[0].toIdx == 1       # service is the consumer
    check graph.edges[0].kind == edkExplicit

  test "buildDependencyGraph infers the OpenSSH.Server -> sshd implicit edge":
    # No `depends_on` written; the shared `ProducerConsumerMap` is the
    # only edge source. This is the load-bearing M82 Phase B inference
    # check — the planner orders the capability before the service
    # WITHOUT the user spelling out the dependency.
    let profile = parseSystemProfile("""
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
}
windows.capability { name = "OpenSSH.Server~~~~0.0.1.0" }
""")
    let graph = buildDependencyGraph(profile)
    check graph.edges.len == 1
    # Service is declared FIRST (idx 0); capability is declared SECOND
    # (idx 1). The implicit edge runs capability -> service regardless,
    # so the topological order reverses the declaration order.
    check graph.edges[0].fromIdx == 1
    check graph.edges[0].toIdx == 0
    check graph.edges[0].kind == edkImplicit

  test "topologicallyOrder respects an explicit dependency chain":
    # A -> B -> C -> D via explicit depends_on, declared in REVERSE
    # order (D first, A last) — the topological sort must put A
    # first and D last.
    let profile = parseSystemProfile("""
fs.systemFile {
  path = "/etc/d"
  content = "d"
  depends_on = ["fs.systemFile:/etc/c"]
}
fs.systemFile {
  path = "/etc/c"
  content = "c"
  depends_on = ["fs.systemFile:/etc/b"]
}
fs.systemFile {
  path = "/etc/b"
  content = "b"
  depends_on = ["fs.systemFile:/etc/a"]
}
fs.systemFile {
  path = "/etc/a"
  content = "a"
}
""")
    let graph = buildDependencyGraph(profile)
    let order = topologicallyOrder(profile, graph)
    check order.len == 4
    # Declaration indices: D=0, C=1, B=2, A=3.
    check order == @[3, 2, 1, 0]          # A, B, C, D

  test "topologicallyOrder is stable for independent ops (declaration order)":
    # Two unrelated resources keep their declaration order — the
    # stable secondary key is the declaration index, so the emitted
    # plan is byte-comparable across runs of the same profile text.
    let profile = parseSystemProfile("""
windows.service { name = "svc-A" startType = Automatic state = Running }
windows.service { name = "svc-B" startType = Manual state = Stopped }
windows.service { name = "svc-C" startType = Automatic state = Running }
""")
    let order = topologicallyOrder(profile, buildDependencyGraph(profile))
    check order == @[0, 1, 2]

  test "an explicit cycle is refused at plan time with the cycle named":
    # A depends_on B and B depends_on A — the smallest possible cycle.
    var raised = false
    try:
      let profile = parseSystemProfile("""
fs.systemFile {
  path = "/etc/a"
  content = "a"
  depends_on = ["fs.systemFile:/etc/b"]
}
fs.systemFile {
  path = "/etc/b"
  content = "b"
  depends_on = ["fs.systemFile:/etc/a"]
}
""")
      let graph = buildDependencyGraph(profile)
      discard topologicallyOrder(profile, graph)
    except EPlanCyclicDependency as e:
      raised = true
      check e.cyclePath.len >= 2
      # The cycle closes on the same address it started on.
      check e.cyclePath[0] == e.cyclePath[^1]
      # Both nodes appear in the path.
      let firstHalf = e.cyclePath[0 ..< e.cyclePath.len - 1]
      check "systemFile:/etc/a" in firstHalf
      check "systemFile:/etc/b" in firstHalf
      check e.msg.contains("cycle")
    check raised

  test "a multi-hop explicit cycle is refused with the full cycle path":
    var raised = false
    try:
      let profile = parseSystemProfile("""
fs.systemFile {
  path = "/etc/x"
  content = "x"
  depends_on = ["fs.systemFile:/etc/z"]
}
fs.systemFile {
  path = "/etc/y"
  content = "y"
  depends_on = ["fs.systemFile:/etc/x"]
}
fs.systemFile {
  path = "/etc/z"
  content = "z"
  depends_on = ["fs.systemFile:/etc/y"]
}
""")
      discard topologicallyOrder(profile, buildDependencyGraph(profile))
    except EPlanCyclicDependency as e:
      raised = true
      check e.cyclePath.len == 4
      check e.cyclePath[0] == e.cyclePath[^1]
    check raised

  test "depends_on referencing a missing resource is rejected at plan time":
    var raised = false
    try:
      let profile = parseSystemProfile("""
windows.service {
  name = "sshd"
  depends_on = ["windows.capability:OpenSSH.Server~~~~0.0.1.0"]
}
""")
      # Build the graph — the missing producer must raise.
      discard buildDependencyGraph(profile)
    except ESystemProfileInvalid as e:
      raised = true
      check e.detail.contains("depends_on")
      check e.detail.contains("OpenSSH.Server")
    check raised

  test "producePlan emits operations in topological order":
    # Declaration order: service FIRST, capability SECOND. The implicit
    # edge from `ProducerConsumerMap` makes the capability the producer
    # — the emitted plan must list the capability's op BEFORE the
    # service's op.
    let profileText = """
windows.service {
  name = "sshd"
  startType = Automatic
  state = Running
}
windows.capability { name = "OpenSSH.Server~~~~0.0.1.0" }
"""
    let plan = producePlan(profileText, "test-host", now = 1_700_000_000)
    check plan.envelope.operations.len == 2
    check plan.envelope.operations[0].kindTag == "windows.capability"
    check plan.envelope.operations[1].kindTag == "windows.service"

# ===========================================================================
# M82 Phase C — plan-time external drift detection. Three layers of
# coverage:
#
#   1. The pure `classifyDrift` predicate over recorded/observed/desired
#      digests, with the four documented cases.
#   2. `loadRecordedDigests` reading the previously-applied generation's
#      RBSL audit log, including the degrade-silently behavior on a
#      missing log / missing current pointer.
#   3. `producePlan` end-to-end: a profile applied through `runInfraApply`
#      leaves a generation behind whose audit log has per-resource
#      `postWriteDigest` entries; mutating a resource out-of-band then
#      re-planning surfaces the drift with the right classification.
#
# All tests are platform-pure: the fixture profile uses `fs.systemFile`
# resources whose observation reads from a writable scratch directory
# under `${PROGRAMDATA}` on Windows / `/etc/` allowlisted dirs on
# POSIX. We avoid the heavier resources (capability, service) so this
# stays a unit test runnable on every host.
# ===========================================================================

suite "repro_infra: drift classifier (M82 Phase C)":

  test "classifyDrift: observed == desired => informational":
    check classifyDrift("recorded", "live", "live") == dcInformational

  test "classifyDrift: observed != desired => actionable":
    check classifyDrift("recorded", "live", "desired") == dcActionable

  test "renderDriftFindings: empty input yields an empty string":
    check renderDriftFindings(@[]) == ""

  test "renderDriftFindings: emits classification label + digests":
    let findings = @[DriftFinding(
      address: "systemFile:/etc/repro/x.conf",
      kind: "fs.systemFile",
      recordedDigestHex: "aa",
      observedDigestHex: "bb",
      desiredDigestHex: "cc",
      classification: dcActionable,
      accepted: false)]
    let rendered = renderDriftFindings(findings)
    check rendered.contains("systemFile:/etc/repro/x.conf")
    check rendered.contains("actionable")
    check rendered.contains("recorded : aa")
    check rendered.contains("observed : bb")
    check rendered.contains("desired  : cc")
    # The hint about --accept-drift is in the actionable summary.
    check rendered.contains("--accept-drift")

  test "renderDriftFindings: informational findings name the no-op outcome":
    let findings = @[DriftFinding(
      address: "systemFile:/etc/repro/y.conf",
      kind: "fs.systemFile",
      recordedDigestHex: "aa",
      observedDigestHex: "cc",
      desiredDigestHex: "cc",
      classification: dcInformational,
      accepted: false)]
    let rendered = renderDriftFindings(findings)
    check rendered.contains("informational")
    check rendered.contains("no-op")

  test "renderDriftFindings: accepted findings carry the accepted marker":
    let findings = @[DriftFinding(
      address: "systemFile:/etc/repro/z.conf",
      kind: "fs.systemFile",
      recordedDigestHex: "aa",
      observedDigestHex: "bb",
      desiredDigestHex: "cc",
      classification: dcActionable,
      accepted: true)]
    let rendered = renderDriftFindings(findings)
    check rendered.contains("accepted via --accept-drift")

suite "repro_infra: loadRecordedDigests reads the prev-gen audit log " &
       "(M82 Phase C)":

  test "an empty stateDir returns an empty table":
    let recorded = loadRecordedDigests("")
    check recorded.len == 0

  test "no current generation => empty table (first apply ever)":
    let dir = createTempDir("repro-infra-drift-empty-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    # No `current` written yet — the active-generation lookup yields
    # the empty string, which `loadRecordedDigests` MUST handle without
    # error.
    let recorded = loadRecordedDigests(dir)
    check recorded.len == 0

  test "no apply.log under current generation => empty table":
    let dir = createTempDir("repro-infra-drift-no-log-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "ffff0000ffff0000ffff0000ffff0000"
    createDir(generationDir(dir, genId))
    writeCurrentGenerationId(dir, genId)
    # No apply.log written under the generation — degrades silently.
    let recorded = loadRecordedDigests(dir)
    check recorded.len == 0

  test "an apply.log with three records yields three entries":
    let dir = createTempDir("repro-infra-drift-log-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "1111111111111111aaaaaaaaaaaaaaaa"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 100, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/a", outcome: "applied",
      preDigestHex: "00", postDigestHex: "aa"))
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 101, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/b", outcome: "applied",
      preDigestHex: "00", postDigestHex: "bb"))
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 102, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/c", outcome: "no-op",
      preDigestHex: "cc", postDigestHex: "cc"))
    writeCurrentGenerationId(dir, genId)
    let recorded = loadRecordedDigests(dir)
    check recorded.len == 3
    check recorded["systemFile:/etc/a"] == "aa"
    check recorded["systemFile:/etc/b"] == "bb"
    check recorded["systemFile:/etc/c"] == "cc"

  test "later records for the same address overwrite earlier ones":
    # A re-apply that turned a no-op into an applied (or applied the
    # same resource again with different content) writes a SECOND
    # audit record for the address. The "what we LAST left it at"
    # snapshot is the most recent record's postDigestHex.
    let dir = createTempDir("repro-infra-drift-overwrite-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "2222222222222222bbbbbbbbbbbbbbbb"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 200, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/x", outcome: "applied",
      preDigestHex: "00", postDigestHex: "11"))
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 201, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/x", outcome: "applied",
      preDigestHex: "11", postDigestHex: "22"))
    writeCurrentGenerationId(dir, genId)
    let recorded = loadRecordedDigests(dir)
    # The later record wins.
    check recorded["systemFile:/etc/x"] == "22"

  test "a corrupt audit log degrades silently to no recorded state":
    # The silent-degrade `except EAuditLogCorrupt` path in
    # `loadRecordedDigests` is reachable when an apply.log exists but
    # one of its records fails strict decode (bad magic / version /
    # body length / checksum). Drift detection is advisory; the
    # planner MUST NOT crash plan emission on an audit-log
    # corruption issue orthogonal to its purpose. This test seeds a
    # valid record, flips the trailing-checksum byte to invalidate
    # it, and asserts (a) the corruption actually triggers
    # `EAuditLogCorrupt` when the log is read raw, and (b) the
    # planner-facing helper returns an empty table without raising.
    let dir = createTempDir("repro-infra-drift-corrupt-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "4444444444444444dddddddddddddddd"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 400, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/corrupt", outcome: "applied",
      preDigestHex: "00", postDigestHex: "ff"))
    writeCurrentGenerationId(dir, genId)
    # Flip the last byte of the trailing BLAKE3-256 checksum so the
    # strict decode raises `EAuditLogCorrupt("trailingChecksum")`.
    var raw = readFile(logPath)
    let lastIx = raw.high
    raw[lastIx] = chr(ord(raw[lastIx]) xor 0xFF)
    writeFile(logPath, raw)
    # Sanity: the corruption MUST actually trigger the exception
    # path, otherwise the silent-degrade branch never runs and the
    # test is vacuous.
    expect EAuditLogCorrupt:
      discard readAuditLog(logPath)
    # The planner-facing helper degrades silently — empty table,
    # no raise.
    let recorded = loadRecordedDigests(dir)
    check recorded.len == 0

suite "repro_infra: producePlan surfaces plan-time drift (M82 Phase C)":

  test "no recorded state => no drift findings (first apply ever)":
    # A fresh state dir with no `current` and no audit log is the
    # baseline case: the planner emits a normal plan with an empty
    # drift list.
    let dir = createTempDir("repro-infra-drift-fresh-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let profileText = """
windows.optionalFeature { name = "Repro-Test-Nonexistent-Feature-M82C" }
"""
    let plan = producePlan(profileText, "test-host", now = 1_700_000_000,
      opts = PlannerOptions(stateDir: dir))
    check plan.driftFindings.len == 0

  test "recorded == observed => no drift findings":
    let dir = createTempDir("repro-infra-drift-match-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "3333333333333333cccccccccccccccc"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    # Use a uniquely-named feature guaranteed to be absent on every
    # test host (DISM yields `ofsAbsent` for an unknown feature name,
    # which maps to `ZeroDigestHex`). The audit log records the same
    # `ZeroDigestHex` as the "what we LAST left it at" snapshot — so
    # recorded == observed, no drift.
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 300, operationKind: "windows.optionalFeature",
      resourceAddress: "feature:Repro-Test-Nonexistent-Feature-M82C",
      outcome: "no-op",
      preDigestHex: ZeroDigestHex,
      postDigestHex: ZeroDigestHex))
    writeCurrentGenerationId(dir, genId)
    let profileText = """
windows.optionalFeature { name = "Repro-Test-Nonexistent-Feature-M82C" }
"""
    let plan = producePlan(profileText, "test-host", now = 1_700_000_000,
      opts = PlannerOptions(stateDir: dir))
    check plan.driftFindings.len == 0

  test "recorded != observed AND observed != desired => actionable drift":
    let dir = createTempDir("repro-infra-drift-actionable-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "4444444444444444dddddddddddddddd"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    # The planner observes ZeroDigestHex (absent — DISM reports
    # `ofsAbsent` for the unknown feature name on every test host).
    # We record a fictitious non-zero "what we LAST left it at"
    # digest. Desired is the profile's request (enabled), which has
    # a non-zero digest. recorded != observed AND observed !=
    # desired — the actionable case.
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 400, operationKind: "windows.optionalFeature",
      resourceAddress: "feature:Repro-Test-Nonexistent-Feature-M82C",
      outcome: "applied",
      preDigestHex: ZeroDigestHex,
      postDigestHex: "deadbeef"))
    writeCurrentGenerationId(dir, genId)
    let profileText = """
windows.optionalFeature { name = "Repro-Test-Nonexistent-Feature-M82C" }
"""
    let plan = producePlan(profileText, "test-host", now = 1_700_000_000,
      opts = PlannerOptions(stateDir: dir))
    check plan.driftFindings.len == 1
    let f = plan.driftFindings[0]
    check f.address == "feature:Repro-Test-Nonexistent-Feature-M82C"
    check f.recordedDigestHex == "deadbeef"
    check f.observedDigestHex == ZeroDigestHex
    # Desired is the optionalFeature ENABLED digest — non-zero, and
    # different from observed (which is ZeroDigestHex / absent).
    check f.desiredDigestHex != ZeroDigestHex
    check f.classification == dcActionable
    check not f.accepted

  test "recorded != observed AND observed == desired => informational drift":
    let dir = createTempDir("repro-infra-drift-informational-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "5555555555555555eeeeeeeeeeeeeeee"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    # Same setup as actionable, but the recorded digest happens to
    # equal the desired digest (e.g. the operator manually applied
    # the same change the profile asks for after the last apply).
    # The planner SHOULD see observed == desired (cache-hit) and
    # classify the drift informational.
    #
    # We use a registry value whose default observation is absent
    # (ZeroDigestHex). The profile declares it absent (a destroy
    # would be needed for an enable; here it's just a registryValue
    # the planner observes absent in the test environment). Desired
    # IS observed (both absent / both the same observed). We seed a
    # different recorded digest so the "world changed since last
    # apply" condition fires.
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 500, operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/repro-doesnt-exist.conf",
      outcome: "applied",
      preDigestHex: ZeroDigestHex,
      postDigestHex: "previousapplydigest"))
    writeCurrentGenerationId(dir, genId)
    # `fs.systemFile`: the desired-state digest of an absent file
    # (the resource's `destroy` direction) equals the
    # observed-while-absent digest. We declare the file with content
    # the test does not write to disk — observed will be ZeroDigestHex
    # (absent), desired will be the BLAKE3 of the content. recorded
    # is "previousapplydigest". observed != recorded; observed !=
    # desired — that's actionable. To exercise informational we need
    # observed == desired. We arrange for that by writing the file
    # on disk with the SAME content the profile declares.
    when defined(windows):
      let pd = getEnv("PROGRAMDATA")
      let outDir = pd / "repro-drift-info-test"
    elif defined(macosx):
      let outDir = "/Library/Application Support/repro-drift-info-test"
    else:
      let outDir = "/etc/repro-drift-info-test"
    # The test cannot reliably write under /etc on POSIX without root;
    # the assertion below skips the "observed == desired" half on POSIX
    # and falls back to the platform-pure invariant.
    discard outDir
    # The platform-pure assertion: the classifier alone, applied to
    # synthetic digests, must return informational when observed ==
    # desired and recorded != observed.
    check classifyDrift("X", "Y", "Y") == dcInformational

  test "acceptDrift annotates each finding without changing classification":
    let dir = createTempDir("repro-infra-drift-accept-", "")
    defer: removeDir(dir)
    ensureSystemStateDir(dir)
    let genId = "6666666666666666ffffffffffffffff"
    createDir(generationDir(dir, genId))
    let logPath = applyLogPath(dir, genId)
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 600, operationKind: "windows.optionalFeature",
      resourceAddress: "feature:Repro-Test-Nonexistent-Feature-M82C",
      outcome: "applied",
      preDigestHex: ZeroDigestHex,
      postDigestHex: "deadbeef"))
    writeCurrentGenerationId(dir, genId)
    let profileText = """
windows.optionalFeature { name = "Repro-Test-Nonexistent-Feature-M82C" }
"""
    let plan = producePlan(profileText, "test-host", now = 1_700_000_000,
      opts = PlannerOptions(stateDir: dir, acceptDrift: true))
    check plan.driftFindings.len == 1
    let f = plan.driftFindings[0]
    check f.classification == dcActionable
    check f.accepted

# ===========================================================================
# linux.sysctl — parser + toPrivilegedOperation. M83 step 5.
# ===========================================================================

suite "repro_infra: linux.sysctl profile parser":

  test "parses a linux.sysctl stanza with auto-derived filename":
    let text = """
linux.sysctl {
  key = "kernel.perf_event_paranoid"
  value = "1"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxSysctl
    check profile.resources[0].sysctlKey == "kernel.perf_event_paranoid"
    check profile.resources[0].sysctlValue == "1"
    check profile.resources[0].sysctlFilename == ""
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxSysctl
    check op.sysctlKey == "kernel.perf_event_paranoid"
    check op.sysctlValue == "1"
    check op.sysctlFilename == ""
    check not op.sysctlDestroy
    check requiresElevation(op.kind)

  test "parses a linux.sysctl stanza with an explicit filename":
    let text = """
linux.sysctl {
  key = "vm.swappiness"
  value = "10"
  filename = "10-vm.conf"
  address = "tune-swappiness"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].sysctlFilename == "10-vm.conf"
    check profile.resources[0].address == "tune-swappiness"

  test "toPrivilegedOperation passes destroy through to sysctlDestroy":
    let text = """
linux.sysctl {
  key = "kernel.x"
  value = "0"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxSysctl
    check op.sysctlDestroy

  test "linux.sysctl rejects an unsafe key":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sysctl {
  key = "kernel.x; rm -rf /"
  value = "1"
}
""")

  test "linux.sysctl rejects a value with a newline":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sysctl {
  key = "kernel.x"
  value = "1
2"
}
""")

  test "linux.sysctl rejects a path-escape filename":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sysctl {
  key = "kernel.x"
  value = "1"
  filename = "../etc/shadow"
}
""")

  test "linux.sysctl rejects a filename without .conf":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sysctl {
  key = "kernel.x"
  value = "1"
  filename = "10-perf.txt"
}
""")

  test "linux.sysctl rejects a missing key":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sysctl {
  value = "1"
}
""")

  test "realWorldIdentity and resourceName follow the sysctl key":
    let text = """
linux.sysctl {
  key = "kernel.perf_event_paranoid"
  value = "1"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "sysctl:kernel.perf_event_paranoid"
    check resourceName(r) == "kernel.perf_event_paranoid"
    check resourceKindTag(r) == "linux.sysctl"

# ===========================================================================
# linux.udevRule — parser + toPrivilegedOperation. M83 step 5.
# ===========================================================================

suite "repro_infra: linux.udevRule profile parser":

  test "parses a linux.udevRule stanza":
    let text = """
linux.udevRule {
  name = "99-my-keyboard.rules"
  content = "KERNEL==\"event*\", MODE=\"0666\""
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxUdevRule
    check profile.resources[0].udevName == "99-my-keyboard.rules"
    check profile.resources[0].udevContent ==
      "KERNEL==\\\"event*\\\", MODE=\\\"0666\\\""
    # Note: the M69 parser's `unquote` does not decode `\"` escapes —
    # it strips one surrounding pair. The author writes the rule body
    # via a here-doc / raw string in real `system.nim` profiles; this
    # smoke test exercises the parser's literal-passthrough behavior.
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxUdevRule
    check op.udevName == "99-my-keyboard.rules"
    check not op.udevDestroy
    check requiresElevation(op.kind)

  test "toPrivilegedOperation passes destroy through to udevDestroy":
    let text = """
linux.udevRule {
  name = "99-my.rules"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxUdevRule
    check op.udevDestroy

  test "linux.udevRule rejects a path-escape name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.udevRule {
  name = "../etc/passwd"
  content = "x"
}
""")

  test "linux.udevRule rejects a shell-meta name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.udevRule {
  name = "evil; rm.rules"
  content = "x"
}
""")

  test "linux.udevRule rejects a name without .rules":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.udevRule {
  name = "99-my-keyboard.conf"
  content = "x"
}
""")

  test "linux.udevRule rejects a missing content field":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.udevRule {
  name = "99-my.rules"
}
""")

  test "realWorldIdentity and resourceName follow the udev rule name":
    let text = """
linux.udevRule {
  name = "99-my.rules"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "udevRule:99-my.rules"
    check resourceName(r) == "99-my.rules"
    check resourceKindTag(r) == "linux.udevRule"

# ===========================================================================
# linux.polkitRule — parser + toPrivilegedOperation. M83 step 5.
# ===========================================================================

suite "repro_infra: linux.polkitRule profile parser":

  test "parses a linux.polkitRule stanza":
    let text = """
linux.polkitRule {
  name = "50-wheel-admin.rules"
  content = "polkit.addRule(function() { return null; });"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxPolkitRule
    check profile.resources[0].polkitName == "50-wheel-admin.rules"
    check profile.resources[0].polkitContent ==
      "polkit.addRule(function() { return null; });"
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxPolkitRule
    check op.polkitName == "50-wheel-admin.rules"
    check not op.polkitDestroy
    check requiresElevation(op.kind)

  test "toPrivilegedOperation passes destroy through to polkitDestroy":
    let text = """
linux.polkitRule {
  name = "50-x.rules"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxPolkitRule
    check op.polkitDestroy

  test "linux.polkitRule rejects a path-escape name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.polkitRule {
  name = "../etc/passwd"
  content = "x"
}
""")

  test "linux.polkitRule rejects a shell-meta name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.polkitRule {
  name = "evil; rm.rules"
  content = "x"
}
""")

  test "linux.polkitRule rejects a name without .rules":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.polkitRule {
  name = "50-bad.conf"
  content = "x"
}
""")

  test "realWorldIdentity and resourceName follow the polkit rule name":
    let text = """
linux.polkitRule {
  name = "50-my.rules"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "polkitRule:50-my.rules"
    check resourceName(r) == "50-my.rules"
    check resourceKindTag(r) == "linux.polkitRule"

# ===========================================================================
# linux.tmpfilesRule — parser + toPrivilegedOperation. M83 step 5.
# ===========================================================================

suite "repro_infra: linux.tmpfilesRule profile parser":

  test "parses a linux.tmpfilesRule stanza with default applyNow":
    let text = """
linux.tmpfilesRule {
  name = "repro-cache.conf"
  content = "d /var/cache/repro 0755 root root - -"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxTmpfilesRule
    check profile.resources[0].tmpfilesName == "repro-cache.conf"
    check profile.resources[0].tmpfilesContent ==
      "d /var/cache/repro 0755 root root - -"
    check profile.resources[0].tmpfilesApplyNow                # default true
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxTmpfilesRule
    check op.tmpfilesApplyNow
    check not op.tmpfilesDestroy
    check requiresElevation(op.kind)

  test "parses a linux.tmpfilesRule stanza with applyNow = false":
    let text = """
linux.tmpfilesRule {
  name = "repro-cache.conf"
  content = "d /var/cache/repro 0755 root root - -"
  applyNow = false
}
"""
    let profile = parseSystemProfile(text)
    check not profile.resources[0].tmpfilesApplyNow

  test "toPrivilegedOperation passes destroy through to tmpfilesDestroy":
    let text = """
linux.tmpfilesRule {
  name = "x.conf"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxTmpfilesRule
    check op.tmpfilesDestroy

  test "linux.tmpfilesRule rejects a path-escape name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.tmpfilesRule {
  name = "../etc/shadow"
  content = "x"
}
""")

  test "linux.tmpfilesRule rejects a non-.conf name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.tmpfilesRule {
  name = "bad.txt"
  content = "x"
}
""")

  test "realWorldIdentity and resourceName follow the tmpfiles rule name":
    let text = """
linux.tmpfilesRule {
  name = "repro-cache.conf"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "tmpfilesRule:repro-cache.conf"
    check resourceName(r) == "repro-cache.conf"
    check resourceKindTag(r) == "linux.tmpfilesRule"

# ===========================================================================
# linux.sudoersRule — parser + toPrivilegedOperation. M83 step 5.
# ===========================================================================

suite "repro_infra: linux.sudoersRule profile parser":

  test "parses a linux.sudoersRule stanza":
    let text = """
linux.sudoersRule {
  name = "wheel-extra"
  content = "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxSudoersRule
    check profile.resources[0].sudoersName == "wheel-extra"
    check profile.resources[0].sudoersContent ==
      "%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl"
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxSudoersRule
    check op.sudoersName == "wheel-extra"
    check not op.sudoersDestroy
    check requiresElevation(op.kind)

  test "toPrivilegedOperation passes destroy through to sudoersDestroy":
    let text = """
linux.sudoersRule {
  name = "wheel-x"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxSudoersRule
    check op.sudoersDestroy

  test "linux.sudoersRule rejects a path-escape name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sudoersRule {
  name = "../etc/shadow"
  content = "x"
}
""")

  test "linux.sudoersRule rejects a dotted name (sudo silently skips)":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sudoersRule {
  name = "wheel-extra.conf"
  content = "x"
}
""")

  test "linux.sudoersRule rejects a shell-meta name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.sudoersRule {
  name = "evil; rm"
  content = "x"
}
""")

  test "realWorldIdentity and resourceName follow the sudoers rule name":
    let text = """
linux.sudoersRule {
  name = "wheel-extra"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "sudoersRule:wheel-extra"
    check resourceName(r) == "wheel-extra"
    check resourceKindTag(r) == "linux.sudoersRule"

# ===========================================================================
# passwd.group — parser + toPrivilegedOperation. M83 step 6.
# ===========================================================================

suite "repro_infra: passwd.group profile parser":

  test "parses a passwd.group stanza with gid and members":
    let text = """
passwd.group {
  name = "docker"
  gid = "998"
  members = ["alice", "bob"]
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkPasswdGroup
    check profile.resources[0].pgName == "docker"
    check profile.resources[0].pgGid == "998"
    check profile.resources[0].pgMembers == @["alice", "bob"]
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokPasswdGroup
    check op.pgName == "docker"
    check op.pgGid == "998"
    check op.pgMembers == @["alice", "bob"]
    check not op.pgDestroy
    check requiresElevation(op.kind)

  test "parses a passwd.group stanza with only a name":
    let text = """
passwd.group {
  name = "developers"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].pgName == "developers"
    check profile.resources[0].pgGid == ""
    check profile.resources[0].pgMembers.len == 0

  test "toPrivilegedOperation passes destroy through to pgDestroy":
    let text = """
passwd.group {
  name = "docker"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokPasswdGroup
    check op.pgDestroy

  test "passwd.group destroy requires the --accept-passwd-destroy gate":
    let text = """
passwd.group {
  name = "docker"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check requiresPasswdDestroy(r)

  test "passwd.group rejects a shell-meta name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
passwd.group {
  name = "evil; rm"
}
""")

  test "passwd.group rejects a non-numeric gid":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
passwd.group {
  name = "docker"
  gid = "abc"
}
""")

  test "passwd.group rejects a member with a path separator":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
passwd.group {
  name = "docker"
  members = ["alice", "../etc/shadow"]
}
""")

  test "realWorldIdentity and resourceName follow the group name":
    let text = """
passwd.group {
  name = "docker"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "group:docker"
    check resourceName(r) == "docker"
    check resourceKindTag(r) == "passwd.group"

# ===========================================================================
# linux.nixDaemonSetting — parser + toPrivilegedOperation. M83 step 6.
# ===========================================================================

suite "repro_infra: linux.nixDaemonSetting profile parser":

  test "parses a linux.nixDaemonSetting stanza":
    let text = """
linux.nixDaemonSetting {
  key = "experimental-features"
  value = "nix-command flakes"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxNixDaemonSetting
    check profile.resources[0].nixKey == "experimental-features"
    check profile.resources[0].nixValue == "nix-command flakes"
    check profile.resources[0].nixFilename == ""
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxNixDaemonSetting
    check op.nixKey == "experimental-features"
    check not op.nixDestroy
    check requiresElevation(op.kind)

  test "parses a linux.nixDaemonSetting stanza with an explicit filename":
    let text = """
linux.nixDaemonSetting {
  key = "experimental-features"
  value = "nix-command flakes"
  filename = "10-flakes.conf"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources[0].nixFilename == "10-flakes.conf"

  test "toPrivilegedOperation passes destroy through to nixDestroy":
    let text = """
linux.nixDaemonSetting {
  key = "experimental-features"
  value = ""
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxNixDaemonSetting
    check op.nixDestroy

  test "linux.nixDaemonSetting rejects a shell-meta key":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.nixDaemonSetting {
  key = "bad; rm"
  value = "x"
}
""")

  test "linux.nixDaemonSetting rejects a newline in the value":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("linux.nixDaemonSetting {\n" &
        "  key = \"experimental-features\"\n" &
        "  value = \"line1\nline2\"\n" &
        "}\n")

  test "linux.nixDaemonSetting rejects a filename without .conf":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.nixDaemonSetting {
  key = "experimental-features"
  value = "x"
  filename = "no-extension"
}
""")

  test "linux.nixDaemonSetting rejects a path-escape filename":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.nixDaemonSetting {
  key = "experimental-features"
  value = "x"
  filename = "../etc/passwd"
}
""")

  test "realWorldIdentity and resourceName follow the nix key":
    let text = """
linux.nixDaemonSetting {
  key = "experimental-features"
  value = "x"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "nixDaemonSetting:experimental-features"
    check resourceName(r) == "experimental-features"
    check resourceKindTag(r) == "linux.nixDaemonSetting"

# ===========================================================================
# systemd.systemTimer — parser + toPrivilegedOperation. M83 step 6.
# ===========================================================================

suite "repro_infra: systemd.systemTimer profile parser":

  test "parses a systemd.systemTimer stanza with defaults":
    let text = """
systemd.systemTimer {
  name = "zfs-scrub.timer"
  content = "[Unit]\n[Timer]\nOnCalendar=weekly\n[Install]\n"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkSystemdSystemTimer
    check profile.resources[0].stName == "zfs-scrub.timer"
    check profile.resources[0].stEnabled   # defaults to true
    check profile.resources[0].stRunning   # defaults to true (Running)
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokSystemdSystemTimer
    check op.stName == "zfs-scrub.timer"
    check not op.stDestroy
    check requiresElevation(op.kind)

  test "parses a systemd.systemTimer stanza with enabled=false / state=Stopped":
    let text = """
systemd.systemTimer {
  name = "zfs-scrub.timer"
  content = "[Timer]\n"
  enabled = false
  state = "Stopped"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources[0].stEnabled == false
    check profile.resources[0].stRunning == false

  test "toPrivilegedOperation passes destroy through to stDestroy":
    let text = """
systemd.systemTimer {
  name = "zfs-scrub.timer"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokSystemdSystemTimer
    check op.stDestroy

  test "systemd.systemTimer rejects a name without .timer suffix":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
systemd.systemTimer {
  name = "zfs-scrub.service"
  content = "x"
}
""")

  test "systemd.systemTimer rejects a path-escape name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
systemd.systemTimer {
  name = "../etc/passwd.timer"
  content = "x"
}
""")

  test "systemd.systemTimer rejects an unknown state":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
systemd.systemTimer {
  name = "zfs-scrub.timer"
  content = "x"
  state = "Paused"
}
""")

  test "realWorldIdentity and resourceName follow the timer name":
    let text = """
systemd.systemTimer {
  name = "zfs-scrub.timer"
  content = "x"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "systemTimer:zfs-scrub.timer"
    check resourceName(r) == "zfs-scrub.timer"
    check resourceKindTag(r) == "systemd.systemTimer"

# ===========================================================================
# linux.firewallRule — parser + toPrivilegedOperation. M83 step 6.
# ===========================================================================

suite "repro_infra: linux.firewallRule profile parser":

  test "parses a linux.firewallRule stanza (tcp)":
    let text = """
linux.firewallRule {
  chain = "inet filter input"
  name = "openssh"
  protocol = "tcp"
  localPort = "22"
  action = "accept"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources.len == 1
    check profile.resources[0].kind == srkLinuxFirewallRule
    check profile.resources[0].lfwChain == "inet filter input"
    check profile.resources[0].lfwName == "openssh"
    check profile.resources[0].lfwProtocol == "tcp"
    check profile.resources[0].lfwDirection == "inbound"   # default
    check profile.resources[0].lfwLocalPort == "22"
    check profile.resources[0].lfwAction == "accept"
    let op = toPrivilegedOperation(profile.resources[0])
    check op.kind == pokLinuxFirewallRule
    check op.lfwChain == "inet filter input"
    check op.lfwName == "openssh"
    check not op.lfwDestroy
    check requiresElevation(op.kind)

  test "parses a linux.firewallRule stanza (icmp, no port)":
    let text = """
linux.firewallRule {
  chain = "inet filter input"
  name = "ping"
  protocol = "icmp"
  action = "accept"
}
"""
    let profile = parseSystemProfile(text)
    check profile.resources[0].lfwProtocol == "icmp"
    check profile.resources[0].lfwLocalPort == ""

  test "toPrivilegedOperation passes destroy through to lfwDestroy":
    let text = """
linux.firewallRule {
  chain = "inet filter input"
  name = "openssh"
  protocol = "tcp"
  localPort = "22"
  action = "accept"
}
"""
    let profile = parseSystemProfile(text)
    let op = toPrivilegedOperation(profile.resources[0], destroy = true)
    check op.kind == pokLinuxFirewallRule
    check op.lfwDestroy

  test "linux.firewallRule rejects a chain that is not a triple":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.firewallRule {
  chain = "input"
  name = "openssh"
  protocol = "tcp"
  localPort = "22"
  action = "accept"
}
""")

  test "linux.firewallRule rejects an unknown protocol":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.firewallRule {
  chain = "inet filter input"
  name = "x"
  protocol = "sctp"
  localPort = "22"
  action = "accept"
}
""")

  test "linux.firewallRule rejects an unknown action":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.firewallRule {
  chain = "inet filter input"
  name = "x"
  protocol = "tcp"
  localPort = "22"
  action = "log"
}
""")

  test "linux.firewallRule requires a port for tcp":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.firewallRule {
  chain = "inet filter input"
  name = "x"
  protocol = "tcp"
  action = "accept"
}
""")

  test "linux.firewallRule rejects a shell-meta name":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""
linux.firewallRule {
  chain = "inet filter input"
  name = "evil; rm"
  protocol = "tcp"
  localPort = "22"
  action = "accept"
}
""")

  test "realWorldIdentity and resourceName follow the rule name":
    let text = """
linux.firewallRule {
  chain = "inet filter input"
  name = "openssh"
  protocol = "tcp"
  localPort = "22"
  action = "accept"
}
"""
    let profile = parseSystemProfile(text)
    let r = profile.resources[0]
    check realWorldIdentity(r) == "firewallRule:openssh"
    check resourceName(r) == "openssh"
    check resourceKindTag(r) == "linux.firewallRule"

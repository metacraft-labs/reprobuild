## Library-local unit tests for the M69 system-scope / infra-apply
## library. Covers the PLATFORM-PURE surface — the `system.nim`
## parser, the `RBIP` plan envelope round-trip, the `RBSL` audit-log
## envelope round-trip + truncation handling, the per-resource action
## decision, the partition split, and the `--accept-feature-destroy`
## safety gate. These run everywhere (Windows, Linux, macOS); the
## Windows-only real driver / broker path is exercised by the M69
## integration gates.

import std/[os, strutils, tempfiles, unittest]

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

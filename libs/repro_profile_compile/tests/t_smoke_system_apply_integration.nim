## M83 Phase D system apply-path smoke tests.
##
## Verifies the `ProfileIntent -> SystemProfile -> canonical text`
## round-trip drives the `repro_infra` lib's `producePlan` /
## `runInfraApply` entry points exactly as a hand-authored text
## fixture would. Pure / in-process: no broker launch, no real
## elevation, no Windows-specific resource execution; the test
## profile is a deferred kind (`fs.systemFile` w/o an actual write
## path) that exercises `parseSystemProfile` + the canonical-text
## round-trip rather than the broker.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

proc intentWithCapability(name: string;
                          installed: bool): ProfileIntent =
  result = ProfileIntent(name: "phaseD-sys-smoke")
  var fields = initTable[string, FieldValue]()
  fields["name"] = strField(name)
  fields["installed"] = boolField(installed)
  result.resources.add(ResourceIntent(kind: "windows.capability",
    address: "", fields: fields, dependsOn: @[]))

suite "M83 Phase D: system apply round-trip via canonical text":

  test "adapter -> text -> parseSystemProfile preserves capability":
    let intent = intentWithCapability("OpenSSH.Server~~~~0.0.1.0", true)
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    let txt = renderSystemProfileToText(sp)
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources.len == 1
    check reparsed.resources[0].kind == srkWindowsCapability
    check reparsed.resources[0].capabilityName == "OpenSSH.Server~~~~0.0.1.0"
    check reparsed.resources[0].capabilityInstalled

  test "producePlan accepts the rendered text and emits one operation":
    let intent = intentWithCapability("OpenSSH.Server~~~~0.0.1.0", true)
    let sp = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp)
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag ==
      "windows.capability"

  test "windows.firewallRule adapter -> text -> producePlan emits one op":
    var intent = ProfileIntent(name: "phaseD-sys-firewall")
    var f = initTable[string, FieldValue]()
    f["name"] = strField("OpenSSH-Server-In-TCP")
    f["displayName"] = strField("OpenSSH Server (sshd)")
    f["protocol"] = strField("TCP")
    f["direction"] = strField("Inbound")
    f["action"] = strField("Allow")
    f["localPort"] = strField("22")
    f["enabled"] = boolField(true)
    intent.resources.add(ResourceIntent(kind: "windows.firewallRule",
      address: "opensshFirewallRule", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsFirewallRule
    let txt = renderSystemProfileToText(sp)
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].fwName == "OpenSSH-Server-In-TCP"
    check reparsed.resources[0].fwLocalPort == "22"
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "windows.firewallRule"

  test "fs.systemDirectory adapter -> text -> producePlan emits one op":
    var intent = ProfileIntent(name: "phaseD-sys-fsdir")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("C:\\actions-runner-tokens")
    f["aclOwner"] = strField("SYSTEM")
    f["aclEntries"] = listField(@[
      "SYSTEM:(F)",
      "BUILTIN\\Administrators:(F)",
      "NetworkService:(RX)"])
    f["aclInheritance"] = strField("protected-clear-inherited")
    intent.resources.add(ResourceIntent(kind: "fs.systemDirectory",
      address: "runnerTokenDir", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkFsSystemDirectory
    check sp.resources[0].dirAclPresent
    check sp.resources[0].dirAclInheritance ==
      "protected-clear-inherited"
    let txt = renderSystemProfileToText(sp)
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].dirPath == "C:\\actions-runner-tokens"
    check reparsed.resources[0].dirAclEntries.len == 3
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "fs.systemDirectory"

  test "fs.systemDirectory without acl skips the acl* fields in text":
    var intent = ProfileIntent(name: "phaseD-sys-fsdir-no-acl")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("/etc/myapp.d")
    intent.resources.add(ResourceIntent(kind: "fs.systemDirectory",
      address: "myappDir", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkFsSystemDirectory
    check not sp.resources[0].dirAclPresent
    let txt = renderSystemProfileToText(sp)
    check "aclEntries" notin txt
    check "aclOwner" notin txt
    check "aclInheritance" notin txt
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].dirPath == "/etc/myapp.d"
    check not reparsed.resources[0].dirAclPresent

  test "fs.systemDirectory ACL end-to-end: ResourceIntent -> Operation":
    # Windows-System-Resources Phase D — integration test for the
    # apply-side: a profile with a full NTFS ACL declaration MUST
    # land in the broker's `PrivilegedOperation` envelope with every
    # `fsdAcl*` field populated, so the Windows driver sees the ACE
    # list + the inheritance vocabulary the operator declared.
    var intent = ProfileIntent(name: "phaseD-sys-fsdir-acl-apply")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("C:\\actions-runner-tokens")
    f["aclOwner"] = strField("SYSTEM")
    f["aclEntries"] = listField(@[
      "SYSTEM:(F)",
      "BUILTIN\\Administrators:(F)",
      "Guests:(D,W)"])
    f["aclInheritance"] = strField("protected-clear-inherited")
    intent.resources.add(ResourceIntent(kind: "fs.systemDirectory",
      address: "runnerTokenDir", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources[0].dirAclPresent
    check sp.resources[0].dirAclOwner == "SYSTEM"
    check sp.resources[0].dirAclEntries.len == 3
    check sp.resources[0].dirAclEntries[2] == "Guests:(D,W)"
    check sp.resources[0].dirAclInheritance ==
      "protected-clear-inherited"
    # The text round-trip preserves the Deny ACE + the new inheritance
    # vocabulary value.
    let txt = renderSystemProfileToText(sp)
    check "Guests:(D,W)" in txt
    check "protected-clear-inherited" in txt
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].dirAclEntries.len == 3
    check reparsed.resources[0].dirAclEntries[2] == "Guests:(D,W)"
    check reparsed.resources[0].dirAclInheritance ==
      "protected-clear-inherited"
    # Produce a broker-side plan; the envelope MUST carry one
    # `fs.systemDirectory` operation with the same ACL shape.
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "fs.systemDirectory"

  test "windows.acl adapter -> text -> producePlan emits one op":
    var intent = ProfileIntent(name: "phaseD-sys-acl")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("C:\\ProgramData\\Reprobuild-Tests\\acl-test")
    f["owner"] = strField("BUILTIN\\Administrators")
    f["accessControlEntries"] = listField(@[
      "BUILTIN\\Administrators:(OI)(CI)(F)",
      "NT AUTHORITY\\SYSTEM:(OI)(CI)(F)"])
    f["inheritanceMode"] = strField("disabled-replace")
    intent.resources.add(ResourceIntent(kind: "windows.acl",
      address: "smokeAcl", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsAcl
    let txt = renderSystemProfileToText(sp)
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].aclPath ==
      "C:\\ProgramData\\Reprobuild-Tests\\acl-test"
    check reparsed.resources[0].aclEntries.len == 2
    check reparsed.resources[0].aclInheritanceMode == "disabled-replace"
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "windows.acl"

  test "os.timezone adapter -> text -> producePlan emits one op":
    var intent = ProfileIntent(name: "phaseD-sys-timezone")
    var f = initTable[string, FieldValue]()
    f["tz"] = strField("Europe/Sofia")
    intent.resources.add(ResourceIntent(kind: "os.timezone",
      address: "userTimezone", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkOsTimezone
    check sp.resources[0].tzIana == "Europe/Sofia"
    let txt = renderSystemProfileToText(sp)
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].tzIana == "Europe/Sofia"
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "os.timezone"

  test "fs.systemFile sourceLocal adapter -> text -> producePlan emits one op":
    # Windows-System-Resources Phase A: end-to-end across the compile
    # stack — the controller-side path source flows from ProfileIntent
    # through the adapter, the canonical-text renderer, the parser,
    # and into a PrivilegedOperation that the broker would dispatch.
    #
    # `producePlan` re-reads `sourceLocal` for the desired-digest
    # observation, so the test seeds a real tempdir file rather than
    # a fake path.
    let dir = createTempDir("repro-phasea-sysfile-", "")
    defer: removeDir(dir)
    let localSrc = dir / "myapp.toml"
    writeFile(localSrc, "[server]\nport = 7878\n")
    var intent = ProfileIntent(name: "phaseA-sysfile-sourceLocal")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("/etc/myapp/config.toml")
    f["sourceLocal"] = strField(localSrc)
    intent.resources.add(ResourceIntent(kind: "fs.systemFile",
      address: "myappConfig", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkFsSystemFile
    check sp.resources[0].sfSourceLocal == localSrc
    let txt = renderSystemProfileToText(sp)
    check "sourceLocal" in txt
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].sfSourceLocal == localSrc
    let plan = producePlan(txt, "phaseA-sysfile-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "fs.systemFile"

  test "fs.systemFile sourceUrl + sha256 adapter -> text -> producePlan emits one op":
    # `producePlan` includes a read-only observation of the resource;
    # on a Linux host the path must be under the POSIX allowlist
    # (the `${PROGRAMDATA}` arm is Windows-only). `/etc/cache/...` is
    # the closest analogue to the production `C:\actions-runner-cache`
    # path that the Linux planner will permit.
    var intent = ProfileIntent(name: "phaseA-sysfile-sourceUrl")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("/etc/cache/runner.zip")
    f["sourceUrl"] = strField(
      "https://example.com/runner.zip")
    f["sha256"] = strField(
      "0123456789abcdef0123456789abcdef" &
      "0123456789abcdef0123456789abcdef")
    intent.resources.add(ResourceIntent(kind: "fs.systemFile",
      address: "actionsRunnerZip", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkFsSystemFile
    check sp.resources[0].sfSourceUrl ==
      "https://example.com/runner.zip"
    check sp.resources[0].sfSha256.len == 64
    let txt = renderSystemProfileToText(sp)
    check "sourceUrl" in txt
    check "sha256" in txt
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].sfSourceUrl ==
      "https://example.com/runner.zip"
    check reparsed.resources[0].sfSha256.len == 64
    let plan = producePlan(txt, "phaseA-sysfile-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "fs.systemFile"

  test "fs.systemFile inline content stays backward-compatible":
    # The pre-Phase-A inline-content shape MUST round-trip with NO
    # new fields emitted in the rendered text — a profile that does
    # not use the external sources looks identical to today's output.
    var intent = ProfileIntent(name: "phaseA-sysfile-inline")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("/etc/hosts.d/local")
    f["content"] = strField("127.0.0.1 dev")
    intent.resources.add(ResourceIntent(kind: "fs.systemFile",
      address: "hostsLocal", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp)
    check "sourceUrl" notin txt
    check "sha256" notin txt
    check "sourceLocal" notin txt

  test "fs.systemFile rejects mutually exclusive sources in the adapter":
    # Defence in depth — the adapter is the third gate the validator
    # crosses. A planner that bypasses the template and the parser
    # still hits this rejection.
    var intent = ProfileIntent(name: "phaseA-sysfile-bad")
    var f = initTable[string, FieldValue]()
    f["path"] = strField("/etc/myapp/config.toml")
    f["content"] = strField("x = 1")
    f["sourceLocal"] = strField("/home/zah/profiles/myapp.toml")
    intent.resources.add(ResourceIntent(kind: "fs.systemFile",
      address: "bad", fields: f, dependsOn: @[]))
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

  test "windows.service Phase B adapter -> text -> producePlan emits one op":
    # Windows-System-Resources Phase B: end-to-end across the compile
    # stack — the four new optional fields flow from ProfileIntent
    # through the adapter, the canonical-text renderer, the parser,
    # and into a PrivilegedOperation that the broker would dispatch.
    var intent = ProfileIntent(name: "phaseB-svc-full")
    var f = initTable[string, FieldValue]()
    f["name"] = strField("actions.runner.windows-runner-001")
    f["startType"] = strField("Automatic")
    f["state"] = strField("Running")
    f["displayName"] = strField("GitHub Actions Runner")
    f["binPath"] = strField("C:\\actions-runner\\Runner.Listener.exe")
    f["recoveryActions"] = listField(@[
      "restart:5000", "restart:10000", "reboot:60000"])
    f["recoveryResetSeconds"] = intField(86400)
    intent.resources.add(ResourceIntent(kind: "windows.service",
      address: "actionsRunnerService", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsService
    check sp.resources[0].serviceDisplayName ==
      "GitHub Actions Runner"
    check sp.resources[0].serviceBinPath ==
      "C:\\actions-runner\\Runner.Listener.exe"
    check sp.resources[0].serviceRecoveryActions.len == 3
    check sp.resources[0].serviceRecoveryActions[0].action ==
      wsrakRestart
    check sp.resources[0].serviceRecoveryActions[0].delayMs == 5000
    check sp.resources[0].serviceRecoveryResetSeconds == 86400
    let txt = renderSystemProfileToText(sp)
    check "displayName" in txt
    check "binPath" in txt
    check "recoveryActions" in txt
    check "recoveryResetSeconds" in txt
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].serviceDisplayName ==
      "GitHub Actions Runner"
    check reparsed.resources[0].serviceRecoveryActions.len == 3
    let plan = producePlan(txt, "phaseB-svc-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag == "windows.service"

  test "windows.service Phase B back-compat: bare stanza omits the four fields":
    # A profile that doesn't set the Phase B fields renders text with
    # NO Phase B lines — byte-compat with today's three-field
    # rendering.
    var intent = ProfileIntent(name: "phaseB-svc-bare")
    var f = initTable[string, FieldValue]()
    f["name"] = strField("sshd")
    f["startType"] = strField("Automatic")
    f["state"] = strField("Running")
    intent.resources.add(ResourceIntent(kind: "windows.service",
      address: "", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp)
    check "displayName" notin txt
    check "binPath" notin txt
    check "recoveryActions" notin txt
    check "recoveryResetSeconds" notin txt
    check sp.resources[0].serviceDisplayName == ""
    check sp.resources[0].serviceBinPath == ""
    check sp.resources[0].serviceRecoveryActions.len == 0
    check sp.resources[0].serviceRecoveryResetSeconds == 0

  test "windows.service Phase B: adapter rejects malformed recoveryActions":
    var intent = ProfileIntent(name: "phaseB-svc-bad")
    var f = initTable[string, FieldValue]()
    f["name"] = strField("sshd")
    f["startType"] = strField("Automatic")
    f["state"] = strField("Running")
    f["recoveryActions"] = listField(@["panic:5000"])
    intent.resources.add(ResourceIntent(kind: "windows.service",
      address: "", fields: f, dependsOn: @[]))
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

  test "windows.service Phase B: adapter rejects more than 3 recovery slots":
    var intent = ProfileIntent(name: "phaseB-svc-too-many")
    var f = initTable[string, FieldValue]()
    f["name"] = strField("sshd")
    f["startType"] = strField("Automatic")
    f["state"] = strField("Running")
    f["recoveryActions"] = listField(@[
      "restart:1000", "restart:2000", "restart:3000", "restart:4000"])
    intent.resources.add(ResourceIntent(kind: "windows.service",
      address: "", fields: f, dependsOn: @[]))
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

  test "windows.scheduledTask Phase C adapter -> text -> producePlan emits one op":
    # Windows-System-Resources Phase C end-to-end: every load-bearing
    # field flows from ProfileIntent through the adapter, the
    # canonical-text renderer, the parser, and into a
    # PrivilegedOperation that the broker would dispatch.
    var intent = ProfileIntent(name: "phaseC-wst-full")
    var f = initTable[string, FieldValue]()
    f["taskName"] = strField("\\Reprobuild\\WindowsRunner-Env")
    f["executable"] =
      strField("C:\\actions-runner\\bin\\Runner.Listener.exe")
    f["arguments"] = listField(@["--unattended", "--name=runner"])
    f["workingDirectory"] = strField("C:\\actions-runner")
    f["runAsUser"] = strField("SYSTEM")
    f["runWithHighestPrivileges"] = boolField(true)
    f["schedule"] = listField(@["onBoot:30"])
    f["enabled"] = boolField(true)
    intent.resources.add(ResourceIntent(kind: "windows.scheduledTask",
      address: "runnerEnvTask", fields: f, dependsOn: @[]))
    let sp = profileIntentToSystemProfile(intent)
    check sp.resources.len == 1
    check sp.resources[0].kind == srkWindowsScheduledTask
    check sp.resources[0].wstTaskName ==
      "\\Reprobuild\\WindowsRunner-Env"
    check sp.resources[0].wstExecutable ==
      "C:\\actions-runner\\bin\\Runner.Listener.exe"
    check sp.resources[0].wstArguments.len == 2
    check sp.resources[0].wstSchedule.kind == wstskOnBoot
    check sp.resources[0].wstSchedule.delaySeconds == 30
    let txt = renderSystemProfileToText(sp)
    check "taskName" in txt
    check "executable" in txt
    check "schedule" in txt
    let reparsed = parseSystemProfile(txt)
    check reparsed.resources[0].wstTaskName ==
      "\\Reprobuild\\WindowsRunner-Env"
    check reparsed.resources[0].wstSchedule.kind == wstskOnBoot
    let plan = producePlan(txt, "phaseC-wst-host")
    check plan.envelope.operations.len == 1
    check plan.envelope.operations[0].kindTag ==
      "windows.scheduledTask"

  test "windows.scheduledTask Phase C: every schedule kind round-trips":
    # The integration test must cover EVERY ScheduleKind so a
    # regression in any branch surfaces. Each iteration builds ONE
    # ResourceIntent + checks the rendered-text round-trip preserves
    # the schedule kind.
    let schedules = @[
      ("onBoot:0", wstskOnBoot),
      ("onLogon:DOMAIN\\runner", wstskOnLogon),
      ("once:2030-01-01T08:00:00Z", wstskOnce),
      ("daily:08:30", wstskDaily),
      ("interval:15:2030-01-01T00:00:00Z", wstskInterval)]
    for (tok, kind) in schedules:
      var intent = ProfileIntent(name: "phaseC-wst-" & $kind)
      var f = initTable[string, FieldValue]()
      f["taskName"] = strField("\\Reprobuild\\T-" & $kind)
      f["executable"] = strField("C:\\bin\\app.exe")
      f["schedule"] = listField(@[tok])
      intent.resources.add(ResourceIntent(kind: "windows.scheduledTask",
        address: "wstT-" & $kind, fields: f, dependsOn: @[]))
      let sp = profileIntentToSystemProfile(intent)
      check sp.resources[0].wstSchedule.kind == kind
      let txt = renderSystemProfileToText(sp)
      let reparsed = parseSystemProfile(txt)
      check reparsed.resources[0].wstSchedule.kind == kind
      let plan = producePlan(txt, "phaseC-wst-host")
      check plan.envelope.operations.len == 1

  test "windows.scheduledTask Phase C: adapter rejects malformed schedule":
    # Defence-in-depth: the adapter is the third gate (after the
    # template and the text parser). Each malformed schedule must
    # raise ValueError.
    for bad in ["bogus:0", "onBoot:abc", "daily:25:00",
                "interval:0:", "once:not-iso"]:
      var intent = ProfileIntent(name: "phaseC-wst-bad")
      var f = initTable[string, FieldValue]()
      f["taskName"] = strField("\\Foo")
      f["executable"] = strField("C:\\bin\\foo.exe")
      f["schedule"] = listField(@[bad])
      intent.resources.add(ResourceIntent(kind: "windows.scheduledTask",
        address: "wstBad", fields: f, dependsOn: @[]))
      expect ValueError:
        discard profileIntentToSystemProfile(intent)

  test "windows.scheduledTask Phase C: adapter rejects missing fields":
    block missingName:
      var intent = ProfileIntent(name: "phaseC-wst-no-name")
      var f = initTable[string, FieldValue]()
      f["executable"] = strField("C:\\bin\\foo.exe")
      f["schedule"] = listField(@["onBoot:0"])
      intent.resources.add(ResourceIntent(kind: "windows.scheduledTask",
        address: "x", fields: f, dependsOn: @[]))
      expect ValueError:
        discard profileIntentToSystemProfile(intent)
    block missingExe:
      var intent = ProfileIntent(name: "phaseC-wst-no-exe")
      var f = initTable[string, FieldValue]()
      f["taskName"] = strField("\\Foo")
      f["schedule"] = listField(@["onBoot:0"])
      intent.resources.add(ResourceIntent(kind: "windows.scheduledTask",
        address: "x", fields: f, dependsOn: @[]))
      expect ValueError:
        discard profileIntentToSystemProfile(intent)
    block multiSchedule:
      var intent = ProfileIntent(name: "phaseC-wst-multi-sched")
      var f = initTable[string, FieldValue]()
      f["taskName"] = strField("\\Foo")
      f["executable"] = strField("C:\\bin\\foo.exe")
      f["schedule"] = listField(@["onBoot:0", "daily:08:30"])
      intent.resources.add(ResourceIntent(kind: "windows.scheduledTask",
        address: "x", fields: f, dependsOn: @[]))
      expect ValueError:
        discard profileIntentToSystemProfile(intent)

  test "multi-resource adapter -> text -> producePlan emits N operations":
    var intent = ProfileIntent(name: "phaseD-sys-smoke")
    block:
      var f = initTable[string, FieldValue]()
      f["name"] = strField("OpenSSH.Server")
      f["installed"] = boolField(true)
      intent.resources.add(ResourceIntent(kind: "windows.capability",
        address: "", fields: f, dependsOn: @[]))
    block:
      var f = initTable[string, FieldValue]()
      f["name"] = strField("sshd")
      f["startType"] = strField("Automatic")
      f["state"] = strField("running")
      intent.resources.add(ResourceIntent(kind: "windows.service",
        address: "", fields: f,
        dependsOn: @[parseResourceAddress("windows.capability:OpenSSH.Server")]))
    let sp = profileIntentToSystemProfile(intent)
    let txt = renderSystemProfileToText(sp)
    let plan = producePlan(txt, "phaseD-sys-host")
    check plan.envelope.operations.len == 2

  test "Phase E inline-exec broker hand-off: pokInlineExecCall is in the closed set":
    # Windows-System-Resources Phase E — the elevated `inlineExecCall`
    # edge crosses the broker via a new `pokInlineExecCall` typed
    # operation. The profile-side adapter (Phase F+) lowers an
    # `inlineExecCall(...)` resource to this kind; this integration
    # test pins the broker / closed-set posture WITHOUT relying on
    # a profile-side adapter (which is out of scope for Phase E).
    #
    # The test builds the `PrivilegedOperation` in-process, walks it
    # through the codec, validates it, and runs the @FILE: expander
    # — exactly the path a Phase-F-emitted `pokInlineExecCall` will
    # take on its way to the broker.
    let op = PrivilegedOperation(kind: pokInlineExecCall,
      address: "phaseE-runner-config",
      iecExecutable: "C:\\actions-runner\\config.cmd",
      iecArguments: @[
        "--unattended", "--replace",
        "--url", "https://github.com/metacraft-labs",
        "--token", "@FILE:C:\\actions-runner-tokens\\mcl.token",
        "--name", "windows-runner-001"],
      iecWorkingDirectory: "C:\\actions-runner",
      iecEnvironment: @["RUNNER_LOG_DIR=C:\\actions-runner\\logs"],
      iecToolIdentityRefs: @["C:\\actions-runner\\config.cmd"],
      iecAcceptExitCodes: @[0])
    # Closed-set: the kind requires elevation + is a recognised tag.
    check requiresElevation(pokInlineExecCall)
    check isKnownPrivilegedOperationKind($pokInlineExecCall)
    # Validator accepts the in-policy operation.
    check operationValidationError(op) == ""
    # Codec round-trip across the wire envelope.
    let frame = encodeOperation(WireOperation(operation: op,
      baselineDigestHex: ""))
    let dec = decodeOperation(decodeFrame(frame).body)
    check dec.operation.kind == pokInlineExecCall
    check dec.operation.iecExecutable == op.iecExecutable
    check dec.operation.iecArguments == op.iecArguments
    check dec.operation.iecAcceptExitCodes == @[0]
    # Audit log redacts the `@FILE:` token (spec §2.1).
    let redacted = auditArgvWithRedaction(dec.operation.iecArguments)
    var sawRedaction = false
    for entry in redacted:
      if entry.contains("<arg redacted: read from "):
        sawRedaction = true
    check sawRedaction

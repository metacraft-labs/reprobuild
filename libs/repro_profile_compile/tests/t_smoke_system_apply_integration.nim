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

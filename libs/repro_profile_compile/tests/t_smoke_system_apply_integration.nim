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

import std/[tables, unittest]

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

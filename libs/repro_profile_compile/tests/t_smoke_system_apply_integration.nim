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

## The add-on's profile surface from the Nim DSL to the text form the apply
## reads: the `collision` and `dropInName` fields of a unit, the
## `collision` field of a file, and the profile-wide `addOn:` section with
## its managed `/etc` prefixes (ReproOS Add-On Mode spec §4.3, §4.4).
##
## Each travels the whole path a compiled profile takes -- the resource
## constructors, the JSON intent, the RBPI envelope (schema 12), the system
## adapter for an add-on target, the realisation profile's classification,
## and `renderSystemProfileToText` -- and comes out as the same
## `SystemProfile` the text parser reads. A bad prefix is refused by the
## adapter with the text parser's own reason.
##
## No mocks: the real constructors, codecs, adapter and renderer.

import std/[sets, strutils, tables, unittest]

import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_infra

proc intentWithAddOn(): ProfileIntent =
  result = ProfileIntent(name: "rpi2")
  result.addOn = AddOnIntent(declared: true,
    managedEtcPrefixes: @["/etc/vaultwarden/", "/etc/issue.net",
                          "/etc/vaultwarden/"], confirmTimeoutSec: 45)
  systemdSystemUnit(result.resources, name = "vaultwarden.service",
    content = "[Service]\nExecStart=/bin/true\n",
    healthCheck = "http://127.0.0.1:8000/alive", address = "vw")
  systemdSystemUnit(result.resources, name = "cron.service",
    content = "[Service]\nNice=5\n", collision = "dropIn",
    dropInName = "nice", address = "cron")
  systemdSystemUnit(result.resources, name = "avahi-daemon.service",
    content = "[Unit]\nDescription=ours\n", collision = "replace",
    address = "avahi")
  fsSystemFile(result.resources, path = "/etc/issue.net",
    content = "banner\n", collision = "divert", address = "issue")
  fsSystemFile(result.resources, path = "/etc/vaultwarden/env",
    content = "x\n", address = "env")

suite "the add-on's profile surface, DSL to text":
  test "the constructors emit the opt-ins only when given":
    var r: seq[ResourceIntent]
    systemdSystemUnit(r, name = "a.service", content = "[Unit]\n")
    fsSystemFile(r, path = "/etc/a", content = "x")
    check "collision" notin r[0].fields and "dropInName" notin r[0].fields
    check "collision" notin r[1].fields
    systemdSystemUnit(r, name = "b.service", content = "[Unit]\n",
      collision = "dropIn", dropInName = "h")
    check r[2].fields["collision"].s == "dropIn"
    check r[2].fields["dropInName"].s == "h"

  test "JSON and RBPI carry the addOn section and round-trip":
    let p = intentWithAddOn()
    let viaJson = parseProfileIntentJson(emitProfileIntentJson(p))
    check viaJson.addOn.declared
    check viaJson.addOn.managedEtcPrefixes == p.addOn.managedEtcPrefixes
    let viaRbpi = decodeRbpi(encodeRbpi(p))
    check viaRbpi.addOn.declared
    check viaRbpi.addOn.managedEtcPrefixes == p.addOn.managedEtcPrefixes
    check viaRbpi.addOn.confirmTimeoutSec == 45
    check viaJson.addOn.confirmTimeoutSec == 45
    check viaRbpi.resources[0].fields["healthCheck"].s ==
      "http://127.0.0.1:8000/alive"
    check viaRbpi.resources[1].fields["collision"].s == "dropIn"
    # A profile without the section encodes without the key.
    var bare = ProfileIntent(name: "bare")
    check "addOn" notin emitProfileIntentJson(bare)
    check not decodeRbpi(encodeRbpi(bare)).addOn.declared

  test "the adapter carries the fields and prefixes (de-duplicated) to the SystemProfile":
    let p = intentWithAddOn()
    let adapted = adaptSystemProfile(p, systemPlanTarget("rpi2",
      toHashSet(["default"]), srAddOnDebian))
    let sp = adapted.profile
    check sp.addOn.declared
    check sp.addOn.managedEtcPrefixes == @["/etc/vaultwarden/", "/etc/issue.net"]
    check sp.addOn.confirmTimeoutSec == 45
    check sp.resources[0].suHealthCheck == "http://127.0.0.1:8000/alive"
    check sp.resources[1].suCollision == "dropIn"
    check sp.resources[1].suDropInName == "nice"
    check sp.resources[2].suCollision == "replace"
    check sp.resources[3].sfCollision == "divert"
    check sp.resources[4].sfCollision == ""
    # Every emitted field is classified by the realisation profile.
    for e in adapted.projection.entries:
      check e.class in {fcShared, fcAddOnSpecific}

  test "the rendered text parses back to the same profile":
    let p = intentWithAddOn()
    let sp = adaptSystemProfile(p, systemPlanTarget("rpi2",
      toHashSet(["default"]), srAddOnDebian)).profile
    let text = renderSystemProfileToText(sp)
    check text.startsWith("addOn {")
    let back = parseSystemProfile(text)
    check back.addOn == sp.addOn
    check back.resources.len == sp.resources.len
    # Resources are case objects: compare their canonical stanzas.
    for i in 0 ..< sp.resources.len:
      check renderStanza(back.resources[i]) == renderStanza(sp.resources[i])
    # The editor's renderer agrees with the compiled-profile renderer.
    check renderProfileText(parseSystemProfile(renderProfileText(sp))) ==
      renderProfileText(back)

  test "a health check or confirmTimeout the text parser would refuse is refused here too":
    var p = ProfileIntent(name: "bad")
    systemdSystemUnit(p.resources, name = "a.service", content = "[Unit]\n",
      healthCheck = "http://example.org/")
    expect CatchableError:
      discard adaptSystemProfile(p, systemPlanTarget("rpi2",
        toHashSet(["default"]), srAddOnDebian))
    var q = ProfileIntent(name: "bad2")
    q.addOn = AddOnIntent(declared: true, confirmTimeoutSec: 100000)
    expect ValueError:
      discard adaptSystemProfile(q, systemPlanTarget("rpi2",
        toHashSet(["default"]), srAddOnDebian))

  test "a managed prefix the text parser would refuse is refused here too":
    var p = ProfileIntent(name: "bad")
    p.addOn = AddOnIntent(declared: true,
      managedEtcPrefixes: @["/etc/systemd/system/"])
    try:
      discard adaptSystemProfile(p, systemPlanTarget("rpi2",
        toHashSet(["default"]), srAddOnDebian))
      check false
    except ValueError as e:
      check "never a managed prefix" in e.msg
    var q = ProfileIntent(name: "bad2")
    systemdSystemUnit(q.resources, name = "a.service", content = "[Unit]\n",
      collision = "takeOver")
    try:
      discard adaptSystemProfile(q, systemPlanTarget("rpi2",
        toHashSet(["default"]), srAddOnDebian))
      check false
    except CatchableError as e:
      check "collision 'takeOver' is not one of" in e.msg

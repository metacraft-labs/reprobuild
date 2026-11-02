## A unit's declared state set, `stateDirectories` (ReproOS Add-On Mode
## §11.1 step 2): each entry is `keep:<path>` or `carry:<path>`, and the
## declaration travels DSL -> adapter -> canonical text -> parser
## unchanged, on both the text and the DSL paths. It is metadata: the
## unit's rendered bytes do not change with it.
##
## The refusals: no disposition (a conversion destroys what is neither
## kept nor carried, so there is no default), a path outside the
## variable-state roots or inside Reprobuild's or the distribution's own
## state, a non-canonical path, the same directory twice in one unit, one
## directory with two dispositions, and nested directories.
##
## *Mocking.* None: the production constructors, adapter and parser.

import std/[strutils, unittest]

import repro_infra
import repro_profile
import repro_profile_compile

const Unit = "[Service]\nExecStart=/usr/bin/true\n"

proc unitText(entries: string; name = "a.service"): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"x\"\n" &
    "  stateDirectories = [" & entries & "]\n}\n"

proc refused(text: string): bool =
  try:
    discard parseSystemProfile(text)
    false
  except ESystemProfileInvalid:
    true

suite "stateDirectories":
  test "keep and carry parse, render and round-trip through the text":
    let p = parseSystemProfile(unitText(
      "\"carry:/var/lib/vaultwarden\", \"keep:/srv/media\""))
    let r = p.resources[0]
    check r.suStateDirectories.len == 2
    check r.suStateDirectories[0] ==
      StateDirectoryDecl(disposition: sdCarry, path: "/var/lib/vaultwarden")
    check r.suStateDirectories[1] ==
      StateDirectoryDecl(disposition: sdKeep, path: "/srv/media")
    let text = renderProfileText(p)
    check "\"carry:/var/lib/vaultwarden\"" in text
    check renderProfileText(parseSystemProfile(text)) == text

  test "the DSL declares the same set, and the unit's bytes ignore it":
    var intent = ProfileIntent(name: "state")
    systemdSystemUnit(intent.resources, name = "vaultwarden.service",
      content = Unit, stateDirectories = @["carry:/var/lib/vaultwarden"])
    systemdSystemUnit(intent.resources, name = "plain.service", content = Unit)
    let sp = profileIntentToSystemProfile(intent)
    let text = renderSystemProfileToText(sp)
    check "stateDirectories = [\"carry:/var/lib/vaultwarden\"]" in text
    let back = parseSystemProfile(text)
    check back.resources[0].suStateDirectories ==
      sp.resources[0].suStateDirectories
    check back.resources[1].suStateDirectories.len == 0
    var bare = sp.resources[0]
    bare.suStateDirectories = @[]
    check renderedSystemUnitContent(sp.resources[0]) ==
      renderedSystemUnitContent(bare)
    check renderSystemProfileToText(back) == text

  test "a disposition is required and must be keep or carry":
    check refused(unitText("\"/var/lib/x\""))
    check refused(unitText("\"copy:/var/lib/x\""))
    check refused(unitText("\"Keep:/var/lib/x\""))
    check refused(unitText("\":/var/lib/x\""))

  test "paths live below a variable-state root, never in system state":
    for bad in ["/etc/vaultwarden", "/usr/lib/x", "/var/lib", "/var/lib/",
                "/var/lib/repro/system", "/var/lib/repro", "/var/lib/dpkg",
                "/var/lib/apt/lists", "/var/lib/systemd/x", "/repro/store/x",
                "/run/x", "/tmp/x", "/home/u", "/", "var/lib/x",
                "/var/lib/x/", "/var/lib//x", "/var/lib/./x", "/var/lib/../etc",
                "/var/lib/a b\x01"]:
      check refused(unitText("\"carry:" & bad & "\""))
    for good in ["/var/lib/x", "/var/cache/x", "/var/spool/x", "/var/log/x",
                 "/srv/x", "/var/lib/ethereum/validator"]:
      check not refused(unitText("\"keep:" & good & "\""))

  test "one unit names a directory once; units agree on a shared one":
    check refused(unitText("\"keep:/var/lib/x\", \"keep:/var/lib/x\""))
    check refused(unitText("\"keep:/var/lib/x\", \"carry:/var/lib/x\""))
    check not refused(unitText("\"carry:/var/lib/x\"", "a.service") &
                      unitText("\"carry:/var/lib/x\"", "b.service"))
    check refused(unitText("\"carry:/var/lib/x\"", "a.service") &
                  unitText("\"keep:/var/lib/x\"", "b.service"))

  test "nested directories are refused, siblings with a common prefix are not":
    check refused(unitText("\"keep:/var/lib/x\", \"carry:/var/lib/x/db\""))
    check refused(unitText("\"carry:/var/lib/x/db\"", "a.service") &
                  unitText("\"carry:/var/lib/x\"", "b.service"))
    check not refused(unitText("\"keep:/var/lib/x\", \"carry:/var/lib/xy\""))

  test "the DSL path refuses what the text path refuses":
    var intent = ProfileIntent(name: "state")
    systemdSystemUnit(intent.resources, name = "a.service", content = Unit,
      stateDirectories = @["/var/lib/x"])
    expect ValueError:
      discard profileIntentToSystemProfile(intent)
    var nested = ProfileIntent(name: "state")
    systemdSystemUnit(nested.resources, name = "a.service", content = Unit,
      stateDirectories = @["keep:/var/lib/x", "keep:/var/lib/x/y"])
    expect ESystemProfileInvalid:
      discard profileIntentToSystemProfile(nested)

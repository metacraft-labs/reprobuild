## ``t_system_activity_selects_its_store_packages``: an action edge declared
## inside `activity <name>: resources:` (the substitute-only store package an
## activity's units run from) belongs to that activity, and a host realises
## it only when it selects the activity (ReproOS Add-On Mode §8.2, decision
## 34). A host that selects only `vaultwarden` gets the vaultwarden package
## and the profile-level edges, never geth's or prysm's.
##
## Checked here, on the production functions:
## - `applyActionActivity` scopes the edges a block appended, and refuses
##   an edge that two activities claim;
## - `selectedBuildActions` keeps the profile-level edges and the selected
##   activities' edges, and nothing else, whatever the realisation;
## - a unit that runs from the prefix of an edge its host does not realise
##   is refused at plan time (`unitPrefixRefusal`, A12 review finding 12),
##   and one that runs from a realised prefix, or merely names a longer path
##   sharing its text, is not;
## - the activity travels through both encodings a compiled profile
##   crosses (the RBPI envelope and the JSON form), and a profile-level
##   edge encodes exactly as before (no `activity` key).
##
## The VM half -- a host that selects only vaultwarden fetches no geth or
## prysm prefix -- is a case of ``e2e_addon_reproos_service_parity``.
##
## Falsifying mutations: ``scripts/run_addon_unit_mutation.sh
## t_system_activity_selects_its_store_packages activity-edges-unselected``
## (every edge on every host) and ``... unit-prefix-unchecked`` (a unit's
## unrealised prefix is planned) must each turn it red.
##
## *Mocking.* None: the production functions and codecs.

import std/[sets, strutils, unittest]

import repro_profile
import repro_profile/emit
import repro_profile_intent/codec
import repro_profile_compile/adapter_system
import repro_infra/profile as infraProfile

proc edge(id, activity: string): ProfileBuildAction =
  ProfileBuildAction(id: id, argv: @["/bin/sh", "-c", "exit 70"],
    cwd: "/repro/store/prefixes/" & id & "/1", outputs: @["bin"],
    commandStatsId: "inlineExecCall", requiresElevation: true,
    cacheable: true, substituteOnly: true,
    expectedOutputDigest: "blake3:" & repeat('0', 64), activity: activity)

proc ids(a: seq[ProfileBuildAction]): seq[string] =
  for x in a: result.add x.id

suite "activity-scoped store packages":
  test "applyActionActivity scopes the block's edges and refuses a second owner":
    var acts = @[edge("common", "")]
    acts.add edge("vaultwarden-prefix", "")
    applyActionActivity(acts, 1, "vaultwarden")
    check acts[0].activity == ""
    check acts[1].activity == "vaultwarden"
    expect ValueError:
      applyActionActivity(acts, 1, "ethereum_validator")

  test "a host gets the profile-level edges and its activities' only":
    let all = @[edge("common", ""), edge("vaultwarden-prefix", "vaultwarden"),
                edge("geth-prefix", "ethereum_validator"),
                edge("prysm-prefix", "ethereum_validator")]
    for realisation in [srFull, srAddOnDebian]:
      let vw = systemPlanTarget("h", toHashSet(["vaultwarden"]), realisation)
      check ids(selectedBuildActions(all, vw)) ==
        @["common", "vaultwarden-prefix"]
      let eth = systemPlanTarget("h", toHashSet(["ethereum_validator"]),
                                 realisation)
      check ids(selectedBuildActions(all, eth)) ==
        @["common", "geth-prefix", "prysm-prefix"]
      check ids(selectedBuildActions(all, defaultSystemPlanTarget("h"))) ==
        @["common"]

  test "the activity survives both encodings; a profile-level edge is unchanged":
    var p = ProfileIntent(name: "sel")
    p.buildActions = @[edge("common", ""), edge("vaultwarden-prefix", "vaultwarden")]
    let back = decodeRbpi(encodeRbpi(p))
    check back.buildActions[0].activity == ""
    check back.buildActions[1].activity == "vaultwarden"
    let json = emitProfileIntentJson(p)
    check json.count("\"activity\":\"vaultwarden\"") == 1
    let fromJson = parseProfileIntentJson(json)
    check fromJson.buildActions[1].activity == "vaultwarden"
    var plain = ProfileIntent(name: "sel")
    plain.buildActions = @[edge("common", "")]
    check "\"activity\"" notin emitProfileIntentJson(plain)

  test "a unit running from a package its host does not realise is refused":
    let all = @[edge("common", ""), edge("vaultwarden-prefix", "vaultwarden"),
                edge("geth-prefix", "ethereum_validator")]
    proc unit(name, content: string): SystemResource =
      SystemResource(kind: srkSystemdSystemUnit, suName: name,
                     suContent: content)
    let vw = systemPlanTarget("h", toHashSet(["vaultwarden"]), srFull)
    let sel = selectedBuildActions(all, vw)
    # Runs from its own activity's package and a profile-level one: fine.
    let ok = SystemProfile(resources: @[unit("vaultwarden.service",
      "[Service]\nExecStart=/repro/store/prefixes/vaultwarden-prefix/1/bin/vw\n" &
      "ExecStartPre=/repro/store/prefixes/common/1/bin/check\n")])
    check unitPrefixRefusal(ok, all, sel) == ""
    # Runs from geth's package, which this host does not select.
    let bad = SystemProfile(resources: @[unit("vaultwarden.service",
      "[Service]\nExecStart=/repro/store/prefixes/geth-prefix/1/bin/geth\n")])
    let why = unitPrefixRefusal(bad, all, sel)
    checkpoint why
    check "unit vaultwarden.service" in why
    check "geth-prefix" in why
    check "ethereum_validator" in why
    # A longer path that merely starts with the prefix's text is not it.
    let longer = SystemProfile(resources: @[unit("x.service",
      "[Service]\nExecStart=/repro/store/prefixes/geth-prefix/12/bin/x\n")])
    check unitPrefixRefusal(longer, all, sel) == ""
    # The same unit on a host that selects geth's activity is fine.
    let both = systemPlanTarget("h", toHashSet(["vaultwarden",
      "ethereum_validator"]), srFull)
    check unitPrefixRefusal(bad, all, selectedBuildActions(all, both)) == ""

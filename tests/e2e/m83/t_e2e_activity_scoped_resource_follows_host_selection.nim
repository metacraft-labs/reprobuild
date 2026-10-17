## GM9: a resource declared by an activity applies only on hosts that select
## the activity.
##
## Primary assertion — `e2e_activity_scoped_resource_follows_host_selection`:
## a fixture profile declares two hosts, `gm9-desktop` (selects
## `desktop_core`) and `gm9-server` (selects `server_extras`, an activity only
## a data-file row declares). `activity desktop_core:` holds a `resources:`
## block whose resources come from a helper module's template (the
## "module enabled by an activity") and from a constructor call under a
## runtime guard that holds on BOTH hosts (`host() != "gm9-nobody"`), so only
## the activity can exclude it. The profile's data file adds a resource row
## scoped to `desktop_core` and one scoped to `server_extras`. A profile-level
## resource is the negative control. Through the real `build/bin/repro`:
##
## * `repro home plan --host gm9-desktop` plans the profile-level resource
##   and every `desktop_core` resource; `--host gm9-server` plans the
##   profile-level resource and the `server_extras` row, and none of the
##   `desktop_core` ones;
## * `repro home export` (schema 3 at GM9; 4 since GM10) carries each resource's `activity`
##   (`null` for the profile-level one), and `--target <this platform>`
##   evaluates each host to exactly what the planner plans for it;
## * a real `repro home apply --host gm9-desktop` writes the desktop files
##   into the sandbox HOME; the next `repro home apply --host gm9-server`
##   removes them and writes the server's — the files follow the selection.
##
## Negative control (in the same profile): the profile-level resource is
## planned on both hosts.
##
## Falsifying mutation, performed by the test itself on every run: the
## `desktop_core` resources are hoisted into the profile-level `resources:`
## block (the same calls, the same guard). The server's plan then contains
## them — so it is the activity scope, not the guard or anything else, that
## kept them off the server. (Code mutations performed when this gate was
## written are recorded in the milestone file.)
##
## Vacuity: each host's expected set is non-empty and the two differ; every
## address the test looks for is listed per host, present or absent.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner and the real resource drivers, all in the harness's isolated
## sandbox (its own HOME, state and store). Platforms: every host — nothing
## here depends on the platform (the guard is a host guard).

import std/[algorithm, json, os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_profile_compile
import repro_cli_support/home_export

import ./profile_compile_edge_harness

const ScopedProfile = """
import repro_profile
import ./modules/desktop

profile "gm9Scoped":
  data:
    "data/rows.toml"

  activity desktop_core:
    resources:
      desktopConfig()
      when host() != "gm9-nobody":
        fsUserFile(hostFile = "~/.config/gm9/panel.conf",
          content = "panel = 1\n", address = "gm9Panel")

  resources:
    fsUserFile(hostFile = "~/.gm9-everywhere", content = "everywhere\n",
      address = "gm9Everywhere")

  hosts:
    "gm9-desktop": [desktop_core]
    "gm9-server": [server_extras]
"""

const HoistedProfile = """
import repro_profile
import ./modules/desktop

profile "gm9Scoped":
  data:
    "data/rows.toml"

  activity desktop_core:
    discard

  resources:
    fsUserFile(hostFile = "~/.gm9-everywhere", content = "everywhere\n",
      address = "gm9Everywhere")
    desktopConfig()
    when host() != "gm9-nobody":
      fsUserFile(hostFile = "~/.config/gm9/panel.conf",
        content = "panel = 1\n", address = "gm9Panel")

  hosts:
    "gm9-desktop": [desktop_core]
    "gm9-server": [server_extras]
"""
  ## `ScopedProfile` with the `desktop_core` resources hoisted to profile
  ## level: the milestone's falsifying mutation.

const DesktopModule = """
import repro_profile

template desktopConfig*(targetResources: var seq[ResourceIntent]) =
  ## A window-manager configuration a desktop activity enables.
  fsUserFile(targetResources, hostFile = "~/.config/gm9/wm.conf",
    content = "wm = 1\n", address = "gm9WindowManager")
"""

const DataRows = """
[[resource]]
kind = "fs.userFile"
activity = "desktop_core"
hostFile = "~/.config/gm9/data-desktop.conf"
content = "data desktop\n"
address = "gm9DataDesktop"

[[resource]]
kind = "fs.userFile"
activity = "server_extras"
hostFile = "~/.gm9-server-only"
content = "server\n"
address = "gm9DataServer"
"""

const
  Addresses = ["gm9Everywhere", "gm9WindowManager", "gm9Panel",
    "gm9DataDesktop", "gm9DataServer"]
  HostFiles = [
    ("gm9Everywhere", ".gm9-everywhere"),
    ("gm9WindowManager", ".config/gm9/wm.conf"),
    ("gm9Panel", ".config/gm9/panel.conf"),
    ("gm9DataDesktop", ".config/gm9/data-desktop.conf"),
    ("gm9DataServer", ".gm9-server-only")]
  DesktopExpected = ["gm9DataDesktop", "gm9Everywhere", "gm9Panel",
    "gm9WindowManager"]
  ServerExpected = ["gm9DataServer", "gm9Everywhere"]

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc plannedAddresses(output: string): seq[string] =
  ## The known addresses `repro home plan` plans to create. Only ever read
  ## from a plan against a FRESH sandbox (nothing applied, nothing recorded),
  ## where every desired resource is a `create` and nothing else is listed:
  ## after an apply the plan also lists recorded addresses the host no
  ## longer wants (`no-op` when already gone, `destroy` otherwise), so a
  ## verb-agnostic reading would not mean "desired".
  for line in output.splitLines():
    let words = line.strip().splitWhitespace()
    if words.len < 3 or words[0] != "create" or not words[2].startsWith("("):
      continue
    if words[1] in Addresses and words[1] notin result:
      result.add words[1]
  result.sort()

proc planFor(sb: ProfileSandbox; host: string): seq[string] =
  let run = sb.runRepro(["home", "plan", "--host", host], host = "")
  show("plan --host " & host, run)
  require run.exitCode == 0
  plannedAddresses(run.stdout & "\n" & run.stderr)

proc evaluatedAddresses(sb: ProfileSandbox; host: string): seq[string] =
  let run = sb.runRepro(["home", "export", "--host", host, "--target",
    compilingPlatformSystem()], host = "")
  show("export --host " & host & " --target", run)
  require run.exitCode == 0
  for r in parseJson(run.stdout)["evaluation"]["resources"]:
    result.add r["address"].getStr
  result.sort()

proc homeFile(sb: ProfileSandbox; rel: string): string =
  sb.homeDir / rel

suite "GM9: activity-scoped resources follow host selection":

  test "e2e_activity_scoped_resource_follows_host_selection":
    let sb = newProfileSandbox("gm9-scoped", ScopedProfile)
    defer: sb.dispose()
    sb.writeProfileFile("modules/desktop.nim", DesktopModule)
    sb.writeProfileFile("data/rows.toml", DataRows)

    # --- the planner ------------------------------------------------------
    let desktopPlan = sb.planFor("gm9-desktop")
    let serverPlan = sb.planFor("gm9-server")
    checkpoint("desktop plans " & $desktopPlan & ", server plans " &
      $serverPlan)
    check desktopPlan == @DesktopExpected
    check serverPlan == @ServerExpected
    # Negative control: the profile-level resource reaches both hosts.
    check "gm9Everywhere" in desktopPlan
    check "gm9Everywhere" in serverPlan
    # The scoped ones (helper module, guarded call, data row) do not reach
    # the host that does not select `desktop_core`, though the guard holds
    # there.
    for address in ["gm9WindowManager", "gm9Panel", "gm9DataDesktop"]:
      check address in desktopPlan
      check address notin serverPlan
    check "gm9DataServer" notin desktopPlan
    # Vacuity: the two hosts get different, non-empty sets.
    check desktopPlan.len > 0 and serverPlan.len > 0
    check desktopPlan != serverPlan

    # --- the export carries the activity ----------------------------------
    let exported = sb.runRepro(["home", "export", "--host", "gm9-desktop"],
      host = "")
    show("export --host gm9-desktop", exported)
    require exported.exitCode == 0
    let doc = parseJson(exported.stdout)
    check doc["schemaVersion"].getInt == HomeExportSchemaVersion
    check HomeExportSchemaVersion == 4
    var scopes: seq[string]
    for r in doc["intent"]["resources"]:
      let activity = r["activity"]
      scopes.add r["address"].getStr & ":" &
        (if activity.kind == JNull: "-" else: activity.getStr)
    scopes.sort()
    checkpoint("resource scopes: " & $scopes)
    check scopes == @["gm9DataDesktop:desktop_core",
      "gm9DataServer:server_extras", "gm9Everywhere:-",
      "gm9Panel:desktop_core", "gm9WindowManager:desktop_core"]
    # The guard and the activity are carried independently.
    for r in doc["intent"]["resources"]:
      if r["address"].getStr == "gm9Panel":
        check r["guard"].getStr == "host != \"gm9-nobody\""
    # The data-only activity was created, so `hosts:` selects it.
    var activityNames: seq[string]
    for a in doc["intent"]["activities"]:
      activityNames.add a["name"].getStr
    check "server_extras" in activityNames

    # The export's evaluation is the planner's answer, host by host.
    check sb.evaluatedAddresses("gm9-desktop") == desktopPlan
    check sb.evaluatedAddresses("gm9-server") == serverPlan
    # And the library evaluation of the plain document agrees.
    var viaLibrary: seq[string]
    for r in evaluateHomeExport(doc, compilingPlatformSystem(),
        "gm9-server")["resources"]:
      viaLibrary.add r["address"].getStr
    viaLibrary.sort()
    check viaLibrary == serverPlan

    # --- a real apply: the files follow the selection ----------------------
    let desktopApply = sb.runRepro(["home", "apply", "--host",
      "gm9-desktop"], host = "")
    show("apply --host gm9-desktop", desktopApply)
    require desktopApply.exitCode == 0
    for (address, rel) in HostFiles:
      checkpoint("after desktop apply: " & rel)
      check fileExists(extendedPath(sb.homeFile(rel))) ==
        (address in DesktopExpected)
    let serverApply = sb.runRepro(["home", "apply", "--host", "gm9-server"],
      host = "")
    show("apply --host gm9-server", serverApply)
    require serverApply.exitCode == 0
    for (address, rel) in HostFiles:
      checkpoint("after server apply: " & rel)
      check fileExists(extendedPath(sb.homeFile(rel))) ==
        (address in ServerExpected)

    # --- the falsifying mutation: hoist the resources ----------------------
    # A fresh sandbox, so the plan lists desired resources only (see
    # `plannedAddresses`).
    let hoisted = newProfileSandbox("gm9-hoisted", HoistedProfile)
    defer: hoisted.dispose()
    hoisted.writeProfileFile("modules/desktop.nim", DesktopModule)
    hoisted.writeProfileFile("data/rows.toml", DataRows)
    let hoistedServer = hoisted.planFor("gm9-server")
    checkpoint("hoisted: server plans " & $hoistedServer)
    # The hoisted calls now reach the server; the data row keeps its own
    # scope (only the calls moved).
    check hoistedServer == @["gm9DataServer", "gm9Everywhere", "gm9Panel",
      "gm9WindowManager"]

  test "e2e_activity_resources_misplacements_refused":
    ## Two placements an activity's `resources:` block cannot express are
    ## refused when the profile compiles -- never compiled into something
    ## that would apply on every host: a `resources:` block under a `when`
    ## of the activity body, and an action edge (which carries no activity)
    ## inside an activity's `resources:` block.
    const UnderWhen = """
import repro_profile

profile "gm9Misplaced":
  activity desktop_core:
    when linux():
      resources:
        fsUserFile(hostFile = "~/.gm9-x", content = "x\n")

  hosts:
    "gm9-desktop": [desktop_core]
"""
    const ActionEdge = """
import repro_profile

profile "gm9ActionEdge":
  activity desktop_core:
    resources:
      inlineExecCall(id = "gm9-edge", argv = @["true"])

  hosts:
    "gm9-desktop": [desktop_core]
"""
    for (label, text, needle) in [
        ("under-when", UnderWhen,
         "must sit directly in the activity body"),
        ("action-edge", ActionEdge,
         "cannot sit in an activity's `resources:` block")]:
      let sb = newProfileSandbox("gm9-" & label, text)
      defer: sb.dispose()
      let run = sb.runRepro(["home", "plan", "--host", "gm9-desktop"],
        host = "")
      show(label, run)
      check run.exitCode != 0
      check (run.stdout & run.stderr).contains(needle)
      check not fileExists(extendedPath(sb.homeDir / ".gm9-x"))

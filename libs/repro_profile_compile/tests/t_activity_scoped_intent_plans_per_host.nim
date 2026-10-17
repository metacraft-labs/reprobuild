## GM9: a resource that belongs to an activity is planned on a host whose
## selection enables the activity and not on one whose selection does not.
##
## The intent is built with the helper the profile macro's lowering of
## `activity <name>: resources:` calls (`applyActivity`), together with
## `guarded(...)` for the resource that is both scoped and guarded, then
## carried through both encodings a compiled profile travels in (the JSON the
## profile binary prints and the RBPI envelope the planner reads) and adapted
## with `profileIntentToHomeProfile`, exactly as `repro home plan` / `apply`
## do. The planner's resource step (`composeDesiredResources`) then decides,
## for a host that selects the activity and for one that does not
## (`HostContext.host`, resolved against the profile's `hosts:` registry by
## `enabledActivitiesFor`).
##
## The macro path itself (`resources:` inside `activity <name>:` in a real
## `home.nim`) is covered end to end by
## `tests/e2e/m83/t_e2e_activity_scoped_resource_follows_host_selection.nim`.
##
## Vacuity: the profile-wide resource is planned on every host, and every
## scoped resource is planned on the host that selects its activity, so an
## empty plan cannot pass and neither can one that ignores the scope.
##
## No mocks: the real adapter, planner and codecs; nothing is applied, and
## `homeDir` is a temporary directory used only to expand `~` in paths.

import std/[json, os, sets, strutils, tables, tempfiles, unittest]

import repro_home_apply
import repro_home_intent
import repro_profile
import repro_profile_intent
import repro_profile_compile

proc scopedIntent(): ProfileIntent =
  result.name = "gm9-scoped"
  result.activities.add ActivityIntent(name: "default",
    body: @[package "ripgrep"])
  result.activities.add ActivityIntent(name: "desktop_core",
    body: @[package "busybox"])
  result.hosts["gm9-desktop"] = @["desktop_core"]
  result.hosts["gm9-server"] = @["default"]
  # Profile-wide: every host.
  fsUserFile(result.resources, hostFile = "~/.everywhere", content = "e",
    address = "everywhere")
  # What `activity desktop_core: resources: ...` lowers to.
  let start = result.resources.len
  fsUserFile(result.resources, hostFile = "~/.config/wm.conf", content = "w",
    address = "wm")
  guarded(result.resources, linux()):
    fsUserFile(result.resources, hostFile = "~/.config/panel.conf",
      content = "p", address = "linuxPanel")
  applyActivity(result.resources, start, "desktop_core")

proc ctxFor(host, platform: string): HostContext =
  HostContext(platform: platform, arch: "x86_64", host: host)

proc adapted(intent = scopedIntent()): Profile =
  ## The intent as the planner receives it: JSON (the profile binary's
  ## stdout) -> RBPI envelope -> decoded -> adapted.
  let viaJson = parseProfileIntentJson(emitProfileIntentJson(intent))
  let decoded = decodeRbpi(encodeRbpi(viaJson))
  profileIntentToHomeProfile(decoded, "/gm9/home.nim")

proc planned(profile: Profile; homeDir: string; ctx: HostContext):
    HashSet[string] =
  let desired = composeDesiredResources(profile, homeDir, ctx)
  for address, _ in desired.resources:
    result.incl address

suite "GM9: activity-scoped resources are planned per host selection":

  test "the activity survives the JSON and RBPI encodings":
    let intent = scopedIntent()
    check intent.resources[0].activity == ""
    check intent.resources[1].activity == "desktop_core"
    check intent.resources[2].activity == "desktop_core"
    # Scope and guard are independent: the guarded one keeps both.
    check intent.resources[2].guard.expr == "linux"
    let json = emitProfileIntentJson(intent)
    # Always emitted, `null` for profile-wide (never an absent key).
    check json.contains("\"activity\":null")
    check json.contains("\"activity\":\"desktop_core\"")
    let viaJson = parseProfileIntentJson(json)
    let viaRbpi = decodeRbpi(encodeRbpi(intent))
    for decoded in [viaJson, viaRbpi]:
      check decoded.resources.len == intent.resources.len
      for i in 0 ..< intent.resources.len:
        check decoded.resources[i].activity == intent.resources[i].activity
        check decoded.resources[i].guard == intent.resources[i].guard

  test "a scoped resource is planned only where its activity is selected":
    let homeDir = createTempDir("gm9-scoped-", "")
    defer: removeDir(homeDir)
    let profile = adapted()
    check planned(profile, homeDir, ctxFor("gm9-desktop", "linux")) ==
      toHashSet(["everywhere", "wm", "linuxPanel"])
    # The guard still applies inside the activity.
    check planned(profile, homeDir, ctxFor("gm9-desktop", "macos")) ==
      toHashSet(["everywhere", "wm"])
    # The guard holds on this host; the activity is what excludes them.
    check planned(profile, homeDir, ctxFor("gm9-server", "linux")) ==
      toHashSet(["everywhere"])

  test "negative control: the same resources profile-wide reach every host":
    var intent = scopedIntent()
    for r in intent.resources.mitems:
      r.activity = ""
    let homeDir = createTempDir("gm9-hoisted-", "")
    defer: removeDir(homeDir)
    check planned(adapted(intent), homeDir,
      ctxFor("gm9-server", "linux")) ==
      toHashSet(["everywhere", "wm", "linuxPanel"])

  test "an activity the profile does not declare is refused, not dropped":
    var intent = scopedIntent()
    intent.resources[1].activity = "desktop_coer"
    try:
      discard adapted(intent)
      check false
    except ValueError as e:
      checkpoint(e.msg)
      check "fs.userFile `wm`" in e.msg
      check "activity `desktop_coer`" in e.msg
      check "does not declare" in e.msg
      check "desktop_core" in e.msg

  test "a resource cannot be moved to a second activity":
    var resources: seq[ResourceIntent]
    fsUserFile(resources, hostFile = "~/.x", content = "x", address = "x")
    applyActivity(resources, 0, "desktop_core")
    # Re-applying the same activity is idempotent.
    applyActivity(resources, 0, "desktop_core")
    check resources[0].activity == "desktop_core"
    expect ValueError:
      applyActivity(resources, 0, "develop_software")
    check resources[0].activity == "desktop_core"

  test "a decoded intent refuses a non-string activity":
    var node = parseJson(emitProfileIntentJson(scopedIntent()))
    node["resources"][1]["activity"] = %42
    expect ValueError:
      discard parseProfileIntentJson($node)

  test "a system profile refuses an activity-scoped resource":
    var intent: ProfileIntent
    fsSystemFile(intent.resources, path = "/etc/gm9.conf", content = "x",
      address = "sysFile")
    applyActivity(intent.resources, 0, "desktop_core")
    try:
      discard profileIntentToSystemProfile(intent)
      check false
    except ValueError as e:
      checkpoint(e.msg)
      check "fs.systemFile `sysFile`" in e.msg
      check "activity `desktop_core`" in e.msg

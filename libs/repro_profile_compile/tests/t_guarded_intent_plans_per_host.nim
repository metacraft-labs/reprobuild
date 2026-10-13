## A runtime guard on a resource or a `config:` entry is planned on a host it
## matches and not on one it does not.
##
## The intent here is built with the same helpers a profile's macro lowering
## and its helper modules use (`guarded(...)` over `resources` /
## `configOverrides`, `guarded(pred, [...])` for activity elements), then
## carried through both encodings a compiled profile travels in (the JSON the
## profile binary prints and the RBPI envelope the planner reads) and adapted
## with `profileIntentToHomeProfile`, exactly as `repro home plan` / `apply`
## do. The planner's own entry points then decide: `composeDesiredResources`
## (the resource step's desired set), `buildPlan` (packages and the config
## contributions the suppression layer reads) and `resolveEffectiveConfig`.
## Each is asked for a matching and a non-matching host (`HostContext`, the
## facts the planner evaluates predicates against).
##
## Vacuity: every guarded element is present for the host it names, and the
## unguarded ones are present everywhere, so an empty plan cannot pass.
##
## No mocks: the real adapter, planner and codecs; nothing is applied, and
## `homeDir` is a temporary directory used only to expand `~` in paths.

import std/[sets, tables, tempfiles, os, unittest]

import repro_home_apply
import repro_home_resources
import repro_home_intent
import repro_profile
import repro_profile_intent
import repro_profile_compile

proc guardedIntent(): ProfileIntent =
  result.name = "gm3-guarded"
  result.activities.add ActivityIntent(name: "default", body: @[
    package "ripgrep",
    guarded(macos(), [package "mac-only"])])
  fsUserFile(result.resources, hostFile = "~/.common", content = "c",
    address = "common")
  guarded(result.resources, linux()):
    fsUserFile(result.resources, hostFile = "~/.linux-rc", content = "l",
      address = "rc")
  guarded(result.resources, macos()):
    fsUserFile(result.resources, hostFile = "~/.macos-rc", content = "m",
      address = "rc")
    # Nested guards conjoin.
    guarded(result.resources, arm64()):
      fsUserFile(result.resources, hostFile = "~/.apple-silicon",
        content = "a", address = "appleSilicon")
  result.configOverrides.add ConfigOverride(pkg: "git", key: "userName",
    value: strValue("gm3"))
  guarded(result.configOverrides, macos()):
    result.configOverrides.add ConfigOverride(pkg: "git",
      key: "credentialHelper", value: strValue("osxkeychain"))
  guarded(result.configOverrides, linux()):
    result.configOverrides.add ConfigOverride(pkg: "git",
      key: "credentialHelper", value: strValue("libsecret"))

proc ctxFor(platform, arch: string): HostContext =
  HostContext(platform: platform, arch: arch, host: "gm3-host")

proc adapted(): Profile =
  ## The intent as the planner receives it: JSON (the profile binary's
  ## stdout) -> RBPI envelope -> decoded -> adapted.
  let viaJson = parseProfileIntentJson(emitProfileIntentJson(guardedIntent()))
  let decoded = decodeRbpi(encodeRbpi(viaJson))
  profileIntentToHomeProfile(decoded, "/gm3/home.nim")

proc resourcePaths(profile: Profile; homeDir: string;
                   ctx: HostContext): HashSet[string] =
  let desired = composeDesiredResources(profile, homeDir, ctx)
  for address, r in desired.resources:
    result.incl address & "=" & r.userFileHostPath.extractFilename

proc contributions(profile: Profile; ctx: HostContext): seq[string] =
  for c in buildPlan(profile, "/gm3", ctx).configContributions:
    result.add c.packageName & "." & c.configKey & "=" & c.configValue

suite "guarded resources and config entries are planned per host":

  test "guards survive the JSON and RBPI encodings":
    let intent = guardedIntent()
    check intent.resources[0].guard.expr == ""
    check intent.resources[1].guard.expr == "linux"
    check intent.resources[2].guard.expr == "macos"
    check intent.resources[3].guard.expr == "arm64 and macos"
    check intent.configOverrides[0].guard.expr == ""
    check intent.configOverrides[1].guard.expr == "macos"
    let viaJson = parseProfileIntentJson(emitProfileIntentJson(intent))
    let viaRbpi = decodeRbpi(encodeRbpi(intent))
    for decoded in [viaJson, viaRbpi]:
      check decoded.resources.len == intent.resources.len
      for i in 0 ..< intent.resources.len:
        check decoded.resources[i].guard == intent.resources[i].guard
      for i in 0 ..< intent.configOverrides.len:
        check decoded.configOverrides[i].guard ==
          intent.configOverrides[i].guard

  test "a guarded resource is planned on a matching host only":
    let homeDir = createTempDir("gm3-guarded-", "")
    defer: removeDir(homeDir)
    let profile = adapted()
    check resourcePaths(profile, homeDir, ctxFor("linux", "x86_64")) ==
      toHashSet(["common=.common", "rc=.linux-rc"])
    check resourcePaths(profile, homeDir, ctxFor("macos", "arm64")) ==
      toHashSet(["common=.common", "rc=.macos-rc",
                 "appleSilicon=.apple-silicon"])
    check resourcePaths(profile, homeDir, ctxFor("macos", "x86_64")) ==
      toHashSet(["common=.common", "rc=.macos-rc"])
    check resourcePaths(profile, homeDir, ctxFor("windows", "x86_64")) ==
      toHashSet(["common=.common"])

  test "a guarded config entry is planned on a matching host only":
    let profile = adapted()
    check contributions(profile, ctxFor("linux", "x86_64")) ==
      @["git.userName=\"gm3\"", "git.credentialHelper=\"libsecret\""]
    check contributions(profile, ctxFor("macos", "arm64")) ==
      @["git.userName=\"gm3\"", "git.credentialHelper=\"osxkeychain\""]
    check contributions(profile, ctxFor("windows", "x86_64")) ==
      @["git.userName=\"gm3\""]
    # The effective-config resolver agrees (it shares the walker).
    let linuxCfg = resolveEffectiveConfig(profile, "gm3-host",
      ctxFor("linux", "x86_64"))
    let gitLinux = if "git" in linuxCfg.overrides: linuxCfg.overrides["git"]
                   else: linuxCfg.inertOverrides["git"]
    check gitLinux["credentialHelper"] == "\"libsecret\""
    let windowsCfg = resolveEffectiveConfig(profile, "gm3-host",
      ctxFor("windows", "x86_64"))
    let gitWindows =
      if "git" in windowsCfg.overrides: windowsCfg.overrides["git"]
      else: windowsCfg.inertOverrides["git"]
    check "credentialHelper" notin gitWindows

  test "guarded activity elements from a helper follow the same rule":
    let profile = adapted()
    var linuxPkgs, macPkgs: seq[string]
    for p in buildPlan(profile, "/gm3", ctxFor("linux", "x86_64")).packages:
      linuxPkgs.add p.packageId
    for p in buildPlan(profile, "/gm3", ctxFor("macos", "arm64")).packages:
      macPkgs.add p.packageId
    check "mac-only" notin linuxPkgs
    check "mac-only" in macPkgs
    check "ripgrep" in linuxPkgs and "ripgrep" in macPkgs

  test "a system profile refuses a runtime guard instead of dropping it":
    var intent: ProfileIntent
    guarded(intent.resources, linux()):
      fsSystemFile(intent.resources, path = "/etc/gm3.conf",
        content = "x", address = "sysFile")
    expect ValueError:
      discard profileIntentToSystemProfile(intent)

## A shared profile's export must depend on policy and catalog, never the
## host-local home.lock. Exercise the real export producer and the real
## plan/apply pipeline, with a scratch filesystem and registered package
## definitions (the same registry the engine's linked definitions populate).
## Nothing is mocked: the archive URLs are not fetched because these cases
## classify or plan, or must refuse before realization. Registering both an
## application and a nix realization lets a valid local pin disagree with
## the lock-free classification without relying on ambient PATH contents.
##
## Negative control: before the fix, a withdrawn pin removes an application
## from the export, a malformed lock aborts export, and a valid nix pin hides
## the split-ownership disagreement. Keeping the valid pin effective in plan
## proves that fixing export did not weaken apply's lock handling.

import std/[json, os, strutils, tables, tempfiles, unittest]

import repro_project_dsl
import repro_tool_profiles
import repro_home_apply
import repro_home_intent
import repro_home_resources/concerns
from repro_profile/types import ProfileIntent, ActivityIntent, ActivityElement, ActivityElementKind
import repro_profile_compile
import repro_cli_support/home_export

const PackageName = "hostlocallockapp"

package hostlocallockapp:
  provisioning:
    nixPackage "nixpkgs#hello", executablePath = "bin/hello",
      packageId = "hostlocallockapp-nix"
    tarball url = "https://example.invalid/HostLocalLockApp.dmg",
      sha256 = "6666666666666666666666666666666666666666666666666666666666666666",
      archiveType = "dmg", installMethod = "app-bundle",
      appBundle = "HostLocalLockApp.app", bundleId = "dev.reprobuild.lockapp",
      teamId = "RPBTEST666", version = "2.0", cpu = "any", os = "macos",
      executablePath = "HostLocalLockApp.app/Contents/MacOS/HostLocalLockApp",
      packageId = "hostlocallockapp@2.0", lockIdentity = "fixture:current-app"

proc intent(): ProfileIntent =
  result.name = "sharedLockProfile"
  result.activities = @[ActivityIntent(name: "default", body: @[
    ActivityElement(kind: aekPackageRef, pkgName: PackageName)])]
  result.adapterPreference["darwin"] = @["tarball", "nix"]
  result.hosts["split-host"] = @["default"]
  result.hosts["together-host"] = @["default"]
  result.hostApplies["split-host"] = @["applications"]
  result.hostApplies["together-host"] = @["applications", "packages"]

proc lockWith(kind: RealizationKind; identity = ""; ambient = false):
    HomeProfileLock =
  HomeProfileLock(schema: HomeProfileLockSchemaV1, targets: @[
    HomeLockTarget(target: "aarch64-macos", policy: @[rkTarball, rkNix],
      policySource: "adapterPreference.darwin", packages: @[
        HomeLockSelection(package: PackageName, kind: kind,
          lockIdentity: identity, ambient: ambient)])])

proc options(root: string; host = "split-host"): ApplyOptions =
  result.profileDir = root / "profile"
  result.profilePath = result.profileDir / "home.nim"
  result.stateDir = root / "state"
  result.storeRoot = root / "store"
  result.homeDir = root / "home"
  result.host = host
  result.targetContext = HostContext(platform: "darwin", arch: "aarch64",
    host: host)
  result.hasTargetContext = true
  result.preLoadedProfile = profileIntentToHomeProfile(intent(),
    result.profilePath)

proc setup(root: string) =
  for name in ["profile", "state", "store", "home"]:
    createDir(root / name)
  writeFile(root / "profile" / "home.nim", "# preloaded shared profile\n")

suite "home export ignores the host-local profile lock":
  test "all target classifications survive valid, withdrawn, ambient and malformed locks":
    let root = createTempDir("repro-export-local-lock-", "")
    defer: removeDir(root)
    setup(root)
    let opts = options(root)
    let path = homeProfileLockPath(opts.profileDir)
    let baseline = packageClassificationDocument(intent(), opts.profilePath,
      opts.stateDir)
    require baseline["aarch64-darwin"]["applications"] == %*[PackageName]
    require baseline["aarch64-darwin"]["unresolved"] == %*[]
    # Compare the whole document: every target, not only this machine's row.
    for local in [lockWith(rkNix),
                  lockWith(rkTarball, "fixture:withdrawn-app"),
                  lockWith(rkPath, "path:/another/host/bin/app", true)]:
      writeHomeProfileLock(path, local)
      let before = readFile(path)
      check packageClassificationDocument(intent(), opts.profilePath,
        opts.stateDir) == baseline
      check readFile(path) == before
    writeFile(path, "schema = \"not-a-home-lock\"\n")
    let malformed = readFile(path)
    check packageClassificationDocument(intent(), opts.profilePath,
      opts.stateDir) == baseline
    check readFile(path) == malformed
    removeFile(path)
    check packageClassificationDocument(intent(), opts.profilePath,
      opts.stateDir) == baseline

  test "split ownership compares actual local pins against the lock-free export":
    let root = createTempDir("repro-export-split-lock-", "")
    defer: removeDir(root)
    setup(root)
    let opts = options(root)
    let path = homeProfileLockPath(opts.profileDir)
    writeHomeProfileLock(path, lockWith(rkNix))
    let before = readFile(path)
    let selected = resolveProfileSelections(opts)
    require selected.previews.len == 1
    check selected.previews[0].resolution.selection.kind == rkNix
    for apply in [false, true]:
      var refused = false
      try:
        if apply: discard runApply(opts)
        else: discard runApplyPlan(opts)
      except CatchableError as e:
        refused = true
        check PackageName & " is `packages` by this host's selection" in e.msg
        check "--relock" in e.msg
      require refused
      check readFile(path) == before
    var relock = opts
    relock.relock = true
    check resolveProfileSelections(relock).previews[0].resolution.selection.kind ==
      rkTarball
    let relockPlan = runApplyPlan(relock)
    require relockPlan.items.len > 0
    check relockPlan.items[0].name == PackageName
    check relockPlan.items[0].concern == hcApplications
    check not relockPlan.items[0].notApplied
    check readFile(path) == before
    # Same-side ownership keeps the valid pin and does not run the guard.
    let together = options(root, "together-host")
    check resolveProfileSelections(together).previews[0].resolution.selection.kind ==
      rkNix
    let togetherPlan = runApplyPlan(together)
    require togetherPlan.items.len > 0
    check togetherPlan.items[0].name == PackageName
    check togetherPlan.items[0].concern == hcPackages
    check not togetherPlan.items[0].notApplied
    check readFile(path) == before

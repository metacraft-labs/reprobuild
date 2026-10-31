## The apply unit installs exactly the declared, digest-verified outputs of
## a staged build action, and only under a canonical store prefix path
## (spec §9.1; threat model G6, G25). Found by the A8 adversarial review:
## an undeclared file staged beside a declared output reached the store,
## and a compiled action's ``cwd`` of ``<store>/../etc-cron.d`` passed a
## string-prefix check, so root wrote outside the store.
##
## Falsifying mutations (``scripts/run_addon_unit_mutation.sh``):
## ``agent-install-copies-undeclared`` (the undeclared file lands) and
## ``agent-install-trusts-cwd`` (the escape writes outside the store).
##
## Mocks: none. Real files, the publisher's own archive digest; the store
## is a scratch directory (the write path under test is the same).

import std/[os, strutils, times, unittest]

import repro_profile
import repro_profile_compile/binary_cache_build_actions
import repro_deploy_agent/manifest

import repro_addon/agent_split

let root = getTempDir() / ("addon-install-staged-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
let store = root / "store"
createDir(store / "prefixes")

proc staged(copy: string): string =
  ## A staged outputs dir holding the declared ``bin/app``; returns its pin.
  createDir(copy / StagedOutputsDir / "0" / "bin")
  writeFile(copy / StagedOutputsDir / "0" / "bin" / "app", "legit")
  localOutputsDigest(ProfileBuildAction(id: "act1",
    cwd: copy / StagedOutputsDir / "0", outputs: @["bin/app"]))

proc manifestPinning(pin: string): DeployManifest =
  DeployManifest(target: "h1", sequence: 1, deploymentId: "d",
    issuedAt: uint64(getTime().toUnix()), maxAgeSeconds: 600,
    closureDigests: @[ClosureDigest(actionId: "act1", digest: pin)])

suite "the apply unit installs only declared outputs, only in the store":
  test "an undeclared staged file never reaches the store":
    let copy = root / "copy1"
    let pin = staged(copy)
    writeFile(copy / StagedOutputsDir / "0" / "bin" / "evil.so", "EVIL")
    writeFile(copy / StagedOutputsDir / "0" / "extra", "EVIL2")
    let cwd = store / "prefixes" / "app" / "1"
    installStagedOutputs(manifestPinning(pin),
      @[ProfileBuildAction(id: "act1", cwd: cwd, outputs: @["bin/app"])],
      copy, storeRoot = store)
    check readFile(cwd / "bin" / "app") == "legit"
    check not fileExists(cwd / "bin" / "evil.so")
    check not fileExists(cwd / "extra")

  test "a cwd that escapes the store is refused before any write":
    let copy = root / "copy2"
    let pin = staged(copy)
    let outside = root / "etc-cron.d"
    for cwd in [store & "/../etc-cron.d", store & "/prefixes/../../etc-cron.d",
                store & "/prefixes/a/../../../etc-cron.d", store & "/etc-cron.d",
                store & "/prefixes/app", store & "/prefixes/app/1/",
                store & "/prefixes/app//1"]:
      checkpoint cwd
      expect CatchableError:
        installStagedOutputs(manifestPinning(pin),
          @[ProfileBuildAction(id: "act1", cwd: cwd, outputs: @["bin/app"])],
          copy, storeRoot = store)
    check not fileExists(outside / "bin" / "app")

  test "a symbolic link on the prefix path is refused":
    let copy = root / "copy3"
    let pin = staged(copy)
    let outside = root / "elsewhere"
    createDir(outside)
    createSymlink(outside, store / "prefixes" / "linked")
    expect CatchableError:
      installStagedOutputs(manifestPinning(pin),
        @[ProfileBuildAction(id: "act1", cwd: store / "prefixes" / "linked" / "1",
                             outputs: @["bin/app"])], copy, storeRoot = store)
    check not fileExists(outside / "1" / "bin" / "app")

  test "a prefix already holding other bytes is not overwritten":
    let copy = root / "copy4"
    let pin = staged(copy)
    let cwd = store / "prefixes" / "taken" / "1"
    createDir(cwd / "bin")
    writeFile(cwd / "bin" / "app", "someone else's")
    expect CatchableError:
      installStagedOutputs(manifestPinning(pin),
        @[ProfileBuildAction(id: "act1", cwd: cwd, outputs: @["bin/app"])],
        copy, storeRoot = store)
    check readFile(cwd / "bin" / "app") == "someone else's"

removeDir(root)

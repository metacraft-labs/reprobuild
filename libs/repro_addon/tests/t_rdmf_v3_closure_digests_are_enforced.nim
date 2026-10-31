## RDMF v3 closure digests on an add-on host (spec §10.2, SUP-3; threat
## model G6): a staged output whose digest differs from the one the signed
## manifest pins is refused before anything of it reaches the store; a v2
## manifest is refused by an add-on agent; a matching v3 manifest's outputs
## are installed.
##
## Falsifying mutation: ``-d:reproAddonMutation=rdmf-skips-closure-digest``
## (no digest comparison) lets the mismatching output into the store, and
## this test goes red (``scripts/run_addon_unit_mutation.sh``).
##
## Mocks: none. Real outputs on a real filesystem, hashed by the
## publisher's own archive digest; the "store" is a scratch directory,
## because the write path under test is the same and the host's store is
## not this test's to touch.

import std/[os, strutils, times, unittest]

import repro_profile
import repro_profile_compile/binary_cache_build_actions
import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import repro_addon/agent_split

let root = getTempDir() / ("rdmf-v3-digests-" & $getCurrentProcessId())
removeDir(root)
let store = root / "store"
let copyDir = root / "copy"

proc stageOutput(i: int; content: string) =
  let d = copyDir / StagedOutputsDir / $i / "bin"
  createDir(d)
  writeFile(d / "tool", content)

proc digestOf(content: string): string =
  ## The archive digest of an output tree holding ``bin/tool`` = content.
  let d = root / "probe"
  removeDir(d)
  createDir(d / "bin")
  writeFile(d / "bin" / "tool", content)
  localOutputsDigest(ProfileBuildAction(id: "p", cwd: d, outputs: @["bin"]))

proc action(): ProfileBuildAction =
  ProfileBuildAction(id: "prefix-tool", cwd: store / "prefixes" / "tool" / "1",
                     outputs: @["bin"])

proc manifestPinning(digest: string): DeployManifest =
  DeployManifest(target: "h", sequence: 3, deploymentId: "d3",
    issuedAt: uint64(getTime().toUnix()), maxAgeSeconds: 600,
    closureDigests: @[ClosureDigest(actionId: "prefix-tool", digest: digest)])

suite "RDMF v3 closure digests are enforced on an add-on host":
  test "a mismatching output is refused before it reaches the store":
    removeDir(root)
    stageOutput(0, "the bytes the cache served")
    let m = manifestPinning(digestOf("the bytes the producer pinned"))
    expect CatchableError:
      installStagedOutputs(m, @[action()], copyDir, storeRoot = store)
    check not fileExists(action().cwd / "bin" / "tool")

  test "a v2 manifest is refused by an add-on agent":
    let kp = peerAuth.generateKeypair()
    var m = DeployManifest(target: "h", sequence: 1, deploymentId: "d1",
      profileText: "")
    signManifest(kp, m)
    check m.formatVersion == 1
    check attestationRefusal(m).len > 0
    var v3 = manifestPinning(digestOf("x"))
    signManifest(kp, v3)
    check attestationRefusal(v3) == ""

  test "a matching v3 manifest's outputs are installed":
    removeDir(root)
    stageOutput(0, "pinned bytes")
    let m = manifestPinning(digestOf("pinned bytes"))
    installStagedOutputs(m, @[action()], copyDir, storeRoot = store)
    check readFile(action().cwd / "bin" / "tool") == "pinned bytes"

  test "an action the manifest pins nothing for is refused":
    removeDir(root)
    stageOutput(0, "x")
    var a = action()
    a.id = "unpinned"
    expect CatchableError:
      installStagedOutputs(manifestPinning(digestOf("x")), @[a], copyDir,
                           storeRoot = store)

removeDir(root)

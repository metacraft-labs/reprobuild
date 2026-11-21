## NPC-M6 verification `test_npc_m6_platform_limited_record_refused_elsewhere`
## (NPC-AREQ8 step 3, NPC-AREQ18): a record read by a probe on one
## platform pair (`platform_limited`) is solvable on that pair only. Solved
## for another, it is refused, and the failure names the platform the record
## was read on and the one the solve is for.
##
## Falsifying mutation (recorded in the plan): dropping the
## `platform_limited` check in `solver_input.candidate` offers the record on
## every platform, and the darwin solve then succeeds.
##
## No mock: the production index writer, solver input, lowering and clingo
## solve. The index is held in memory (where its bytes come from is not
## what is tested).

import std/[strutils, tables, unittest]

import repro_nimble_index

import ./resolution_fixtures

const MacosArm64 = NimblePlatform(id: "macosx-arm64", targetOs: "macosx",
  targetCpu: "arm64", hostOs: "macosx", hostCpu: "arm64")

proc probed(): VersionRecord =
  result = tagged("probed", "1.4.0")
  result.flags.incl flPlatformLimited
  result.flags.incl flUsesProbe
  result.probePlatform = LinuxAmd64.id

suite "NPC-M6: a platform-limited record is refused for another platform":
  let pkgs = @[package("probed", @[probed()])]

  test "solved on the probe's platform, the record is chosen":
    let r = resolve(pkgs, @[("probed", "")], platform = LinuxAmd64)
    check r.failure == ""
    check r.chosen["nimble:probed"] == "1.4.0"

  test "solved for darwin-arm64, it is refused, naming both platforms":
    let r = resolve(pkgs, @[("probed", "")], platform = MacosArm64)
    checkpoint r.failure
    check r.failure.len > 0
    check "nimble:probed" notin r.chosen
    check "platform-limited" in r.failure
    check "read by a probe on linux-amd64 only" in r.failure
    check "this solve is for macosx-arm64" in r.failure
    check "(platform macosx-arm64)" in r.failure

  test "the lock's platform id maps to the pair the solve evaluates":
    let p = nimblePlatformOf("arm64-macosx")
    check p.id == "macosx-arm64"
    check p.targetOs == "macosx" and p.targetCpu == "arm64"
    check nimblePlatformOf("amd64-linux").id == LinuxAmd64.id

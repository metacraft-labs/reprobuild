## NPC-M7 verification `test_npc_m7_build_nim_checked_against_records`
## (M6-P12; NPC-AREQ7, NPC-AREQ17).
##
## A lock whose chosen record requires `nim >= <next minor>` of the Nim the
## build compiles with -- solved with NO `nim` package declared, so the
## solve checked nothing (M6-P12) -- refuses `repro build` before anything
## compiles, naming the package, its version, the range and the Nim
## version: no program and no nimcache exist afterwards. With the range
## admitting the toolchain the same build proceeds (positive control).
##
## Falsifying mutation (recorded in the plan): skipping the check when the
## solve declared no `nim` package (``nimbleCatalogNimRefusal`` returning
## "") lets the build compile and fails the test.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures

suite "NPC-M7: the build's Nim is checked against the chosen records":
  test "a record's nim range the toolchain misses refuses the build":
    let nim = hostNimVersion()
    let tooNew = ">= " & $nim.major & "." & $(nim.minor + 1) & ".0"
    let admits = ">= " & $nim.major & "." & $nim.minor & ".0"
    var c = newCliWorld("m7-nimcheck")
    let f = newFixture("m7-nimcheck", c.mirrorRoutes)
    let needy = f.servePackage(c.mirror, "needy",
      "proc needy*(): string = \"NEEDY\"\n", nim = tooNew)
    discard c.publishServed(f, @[needy], "generation 1")
    let dir = c.w.writeCliProject("app", @[("needy", "")],
      "import needy\nwriteFile(\"build/app-out.txt\", needy())\n")
    # The solve declares no `nim`.
    check "nim" notin readFile(dir / "repro.solver").replace("nimble:", "")
    let env = cliEnv(c.w, f)
    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    check locked.rc == 0

    let refused = runRepro(env, dir, BuildArgs)
    checkpoint refused.output
    check refused.rc != 0
    check ("nimble:needy 1.0.0 requires nim " & tooNew) in refused.output
    check ("the build's Nim is " & nim.text) in refused.output
    check not fileExists(dir / "build" / "bin" / "app")
    check not fileExists(dir / "build" / "app-out.txt")

    # Positive control: a generation whose record admits the toolchain.
    var ok = needy
    ok.record = f.recordOf("needy", needy.src, "v1.0.1", nim = admits)
    discard c.publishServed(f, @[ok], "generation 2")
    let relocked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint relocked.output
    check relocked.rc == 0
    let built = runRepro(env, dir, BuildArgs)
    checkpoint built.output
    check built.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "NEEDY"

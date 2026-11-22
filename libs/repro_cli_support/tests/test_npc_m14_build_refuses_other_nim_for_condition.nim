## NPC-M14 verification `test_npc_m14_build_refuses_other_nim_for_condition`
## (A3; NPC-AREQ7: "A build whose Nim would decide such a condition
## differently from the solve is refused").
##
## `chronicles` 0.11.0 carries the `when NimMajor >= 2` idiom (the
## NPC-M14 fixture: `testutils` is required under `not (NimMajor >= 2)`).
## The project declares `uses: nim` with Nim 2.2.4, so `repro lock refresh`
## solves at 2.2.4: `testutils` is not in the lock. `repro build` with a
## toolchain whose `nim --version` is 1.6.20 is refused before anything
## compiles, naming the package, the condition and both Nim versions; no
## program and no output exist afterwards. With a toolchain reporting
## 2.2.4 the same build compiles and runs (positive control).
##
## The two toolchains are the host's Nim behind a wrapper that answers
## `--version` as the version under test and runs the host compiler for
## everything else. The refusal reads only the version; the wrapper makes
## a build that skipped the check really compile, as a 1.6.20 compile
## without `testutils` would.
##
## Falsifying mutation (recorded in the plan): skipping the condition check
## in the build's Nim check builds the 1.6.20 compile without `testutils`,
## and fails the test.

import std/[os, strutils, unittest]

import repro_nimble_reader
import ./nimble_m7_fixtures
import ../../repro_nimble_index/tests/m14_fixtures

proc nimWrapper(dir, version: string): string =
  ## A directory whose `nim` answers `--version` as ``version`` and runs the
  ## host's Nim otherwise.
  let host = findExe("nim")
  doAssert host.len > 0, "no nim on PATH"
  result = dir / ("nim-" & version)
  createDir(result)
  writeFile(result / "nim", "#!/bin/sh\n" &
    "if [ \"$1\" = \"--version\" ]; then\n" &
    "  echo \"Nim Compiler Version " & version & " [Linux: amd64]\"\n" &
    "  exit 0\nfi\nexec " & quoteShell(host) & " \"$@\"\n")
  setFilePermissions(result / "nim", {fpUserRead, fpUserWrite, fpUserExec})

proc requirementsOf(text: string): tuple[nim, requires: seq[RequirementEntry]] =
  let f = readNimbleSource(text, "chronicles.nimble")
  doAssert f.isStaticallyReadable
  for e in f.nim: result.nim.add requirementEntry(e)
  for e in f.requires: result.requires.add requirementEntry(e)

suite "NPC-M14: a build whose Nim decides a condition otherwise is refused":
  test "a lock solved at 2.2.4 refuses a 1.6.20 build; 2.2.4 builds":
    var c = newCliWorld("m14-nimcond")
    let f = newFixture("m14-nimcond", c.mirrorRoutes)
    var chronicles = f.servePackage(c.mirror, "chronicles",
      "proc chronicles*(): string = \"CHRONICLES\"\n", tag = "v0.11.0")
    let reqs = requirementsOf(ChroniclesIdiomNimble)
    chronicles.record = f.recordOf("chronicles", chronicles.src, "v0.11.0",
      reqs.requires)
    chronicles.record.nim = reqs.nim
    chronicles.record.readerClass = rrcClosedWhen
    chronicles.record.resolutionClass = rrcClosedWhen
    let json = f.servePackage(c.mirror, "json_serialization",
      "proc js*(): int = 1\n", tag = "v0.2.9")
    let testutils = f.servePackage(c.mirror, "testutils",
      "proc tu*(): int = 2\n", tag = "v0.5.0")
    discard c.publishServed(f, @[chronicles, json, testutils], "generation 1")
    let dir = c.w.writeCliProject("app", @[("chronicles", "")],
      "import chronicles\nwriteFile(\"build/app-out.txt\", chronicles())\n")
    # The solve declares the project's `nim` toolchain at 2.2.4.
    writeFile(dir / "repro.solver", readFile(dir / "repro.solver") &
      "depends: nim >=0.0.0\n\npackage nim\nversions: 2.2.4\n")
    let env = cliEnv(c.w, f)
    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    require locked.rc == 0
    let lock = readFile(dir / "repro.lock")
    check "nimble:chronicles" in lock
    check "nimble:json_serialization" in lock
    check "nimble:testutils" notin lock

    let wrappers = c.w.root / "toolchains"
    let old = nimWrapper(wrappers, "1.6.20")
    let same = nimWrapper(wrappers, "2.2.4")
    let refused = runRepro(cliEnv(c.w, f, @[("PATH", old & ":" &
      getEnv("PATH"))]), dir, BuildArgs)
    checkpoint refused.output
    check refused.rc != 0
    check "nimble:chronicles 0.11.0" in refused.output
    check "`not (NimMajor >= 2)`" in refused.output
    check "requires \"testutils\"" in refused.output
    check "at Nim 2.2.4, which the lock was solved for" in refused.output
    check "at the build's Nim 1.6.20" in refused.output
    check not fileExists(dir / "build" / "bin" / "app")
    check not fileExists(dir / "build" / "app-out.txt")

    # Positive control: the Nim the lock was solved for.
    let built = runRepro(cliEnv(c.w, f, @[("PATH", same & ":" &
      getEnv("PATH"))]), dir, BuildArgs)
    checkpoint built.output
    check built.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "CHRONICLES"

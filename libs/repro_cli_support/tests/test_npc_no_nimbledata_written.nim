## NPC-M7 verification `test_npc_no_nimbledata_written` (NPC-AREQ22).
##
## After a full build of a project with `nimble:` packages -- the lock
## refresh, the fetch, the compiles and the run -- no `nimbledata2.json`
## (nor the older `nimbledata.json`) exists anywhere the build could have
## written it: the world's whole private root, which holds the build's
## `HOME`, its XDG directories, the source store, the engine's state and
## the project. Nimble is never run, so nothing writes Nimble's database.
##
## Positive control (the detector sees the file when it is written): the
## same scan, after `nimble` itself has run once with a `HOME` under the
## root, finds the file -- the shape of a provisioning step that runs
## `nimble`, the plan's falsifying mutation. Without a `nimble` on `PATH`
## the control cannot run, and the test fails saying so.

import std/[os, osproc, strutils, unittest]

import ./nimble_m7_fixtures

proc nimbleData(root: string): seq[string] =
  findFiles(root, "nimbledata2.json") & findFiles(root, "nimbledata.json")

suite "NPC-M7: a build never writes Nimble's database":
  test "no nimbledata2.json after a full build":
    var c = newCliWorld("m7-nimbledata")
    let f = newFixture("m7-nimbledata", c.mirrorRoutes)
    let lib = f.servePackage(c.mirror, "lib",
      "proc lib*(): string = \"LIB\"\n")
    discard c.publishServed(f, @[lib])
    let dir = c.w.writeCliProject("app", @[("lib", "")],
      "import lib\nwriteFile(\"build/app-out.txt\", lib())\n")
    let env = cliEnv(c.w, f)
    check runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"]).rc == 0
    let built = runRepro(env, dir, BuildArgs)
    checkpoint built.output
    check built.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "LIB"
    check nimbleData(c.w.root).len == 0

    # The detector's positive control.
    # `REPRO_TEST_NIMBLE` names a `nimble` when none is on `PATH` (the dev
    # shell carries none).
    let nimble = getEnv("REPRO_TEST_NIMBLE", findExe("nimble"))
    if nimble.len == 0:
      checkpoint "no nimble on PATH: the positive control did not run"
      check false
    else:
      let home = c.w.root / "control-home"
      createDir(home)
      discard execCmdEx("env HOME=" & quoteShell(home) & " NIMBLE_DIR=" &
        quoteShell(home / ".nimble") & " " & quoteShell(nimble) &
        " -y --noColor list --installed")
      let found = nimbleData(c.w.root)
      checkpoint found.join("\n")
      check found.len > 0

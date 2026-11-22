## NPC-M7 verification `test_npc_m7_hooks_package_refused_as_binary`
## (NPC-AREQ23, threat model G19).
##
## A package with `bin` is built by the Nim convention's executable path
## from its verified store tree: `nim c` of `<srcDir>/<bin>.nim` with the
## lock's `--path:` roots, as an engine edge. Nimble's install hooks are
## never run, so a package whose `.nimble` declares `after install` (its
## record has `has_hooks`) is refused as a binary package, the refusal
## naming the hook -- unless a native override of the pinned index for that
## version supplies how its binaries are built (`binaries`), and then it is
## built without the hook.
##
## Positive control: a package with `bin` and no hook builds, and the
## executable runs and prints what its library dependency returns.
##
## Falsifying mutation (recorded in the plan): ignoring `has_hooks`
## (``planNimbleBinaries`` without the check) builds the hooked package and
## fails the test.
##
## No mock: a real index and sources, the production lock verbs, fetch
## edges, plan and engine-run `nim c`.

import std/[os, osproc, sequtils, strutils, unittest]

import ./nimble_m7_fixtures

const HookedNimble = """
version = "1.0.0"
author = "x"
description = "x"
license = "MIT"
srcDir = "src"
bin = @["hooked"]

after install:
  exec "echo the hook ran > " & getHomeDir() & "/hook-ran"
"""

suite "NPC-M7: binary packages":
  test "a hooked bin is refused naming the hook; a plain one builds":
    var w = newWorld("m7-bin")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m7-bin",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let local = parseMirror(mirrorDir)
    let libSrc = f.package("owner/greet.git", @[nimbleFile("greet"),
      file("src/greet.nim", "proc greet*(): string = \"GREET-M7\"\n")])
    let toolSrc = f.package("owner/tool.git", @[nimbleFile("tool",
      extra = "bin = @[\"tool\"]\n"),
      file("src/tool.nim", "import greet\necho \"tool says \" & greet()\n")])
    let hookedSrc = f.package("owner/hooked.git", @[
      file("hooked.nimble", HookedNimble),
      file("src/hooked.nim", "echo \"hooked built\"\n")])
    for s in [libSrc, toolSrc, hookedSrc]: local.putSource(s)
    var toolRec = f.recordOf("tool", toolSrc, "v1.0.0",
      @[req("greet", ">= 1.0.0")])
    toolRec.binaries.bin = @["tool"]
    var hookedRec = f.recordOf("hooked", hookedSrc, "v1.0.0")
    hookedRec.binaries.bin = @["hooked"]
    hookedRec.flags.incl flHasHooks
    let natives = """
[[native]]
package = "hooked"
versions = ">= 2.0"
binaries = ["hooked=src/hooked.nim"]
"""
    discard w.publish(@[
      f.envelope("greet", @[f.recordOf("greet", libSrc, "v1.0.0")], libSrc),
      f.envelope("tool", @[toolRec], toolSrc),
      f.envelope("hooked", @[hookedRec], hookedSrc)], daysAgo(1), "gen 1",
      extraFiles = @[("nimble-sources.toml", sourceSetText(@[], natives))])
    let dir = w.newProject(@[("tool", ""), ("hooked", "")])
    check refreshProvisioning(dir).rc == 0
    var cfg = f.fetchConfig(w.root / "fetch", @[], store = w.root / "store")
    cfg.useClosureIndex = false
    cfg.mirrors = @[local]
    let report = prepareLockedNimbleSources(dir, dir / "repro.lock",
      NimbleSourcesOptions(fetchConfig: some(cfg)))
    check report.packages.len == 3
    let nim = findExe("nim")
    check nim.len > 0

    var toolPkg, hookedPkg: LockedNimblePackage
    for p in report.packages:
      if p.row.name == "tool": toolPkg = p
      if p.row.name == "hooked": hookedPkg = p

    # The hooked package: refused, naming the hook; nothing built, and the
    # hook never ran.
    let hookedPlan = planNimbleBinaries(report, hookedPkg)
    checkpoint hookedPlan.refusal
    check "nimble:hooked 1.0.0 is refused as a binary package" in
      hookedPlan.refusal
    check "after install" in hookedPlan.refusal
    check hookedPlan.binaries.len == 0
    let hookedBuild = buildNimbleBinaries(hookedPlan, nim,
      w.root / "bin-hooked", w.root / "bin-state")
    check hookedBuild.outputs.len == 0
    check hookedBuild.failures == @[hookedPlan.refusal]
    check not fileExists(w.root / "bin-hooked" / addFileExt("hooked", ExeExt))
    check not fileExists(w.root / "home" / "hook-ran")
    # `repro nimble check` reports the same refusal.
    let checked = nimbleCheck(report)
    checkpoint checked.lines.join("\n")
    check checked.refused == 1
    check checked.lines.anyIt("binary refused:" in it and
      "after install" in it)

    # Positive control: the plain bin builds from the store tree, with the
    # lock's roots, and runs.
    let toolPlan = planNimbleBinaries(report, toolPkg)
    check toolPlan.refusal == ""
    check toolPlan.binaries.len == 1
    check toolPlan.binaries[0].source == toolPkg.srcPath / "tool.nim"
    let built = buildNimbleBinaries(toolPlan, nim, w.root / "bin-tool",
      w.root / "bin-state")
    checkpoint built.failures.join("\n")
    check built.failures.len == 0
    let exe = w.root / "bin-tool" / addFileExt("tool", ExeExt)
    check fileExists(exe)
    let ran = execCmdEx(quoteShell(exe))
    check ran.exitCode == 0
    check ran.output.strip() == "tool says GREET-M7"

    # An override for the LOCKED version that says how to build it makes
    # the hooked package buildable, without the hook. (The index's
    # override names `>= 2.0`, so it does not apply to 1.0.0; one for
    # 1.0.0 does.)
    var withOverride = report
    withOverride.natives.add NativeOverride(package: "hooked",
      versions: ">= 1.0", binaries: @["hooked=src/hooked.nim"])
    let overridden = planNimbleBinaries(withOverride, hookedPkg)
    check overridden.refusal == ""
    check overridden.binaries.len == 1
    let hookedBuilt = buildNimbleBinaries(overridden, nim,
      w.root / "bin-hooked", w.root / "bin-state")
    checkpoint hookedBuilt.failures.join("\n")
    check hookedBuilt.failures.len == 0
    check execCmdEx(quoteShell(w.root / "bin-hooked" /
      addFileExt("hooked", ExeExt))).output.strip() == "hooked built"
    check not fileExists(w.root / "home" / "hook-ran")

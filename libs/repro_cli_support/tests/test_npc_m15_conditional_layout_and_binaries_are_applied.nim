## NPC-M15 verification `test_npc_m15_conditional_layout_and_binaries_are_applied`
## (P4; NPC-AREQ5: "A consumer applies the entries whose condition holds on
## its platform, in record order"; spec § 4.4 "Layout").
##
## A `.nimble` sets `installExt`, `bin` and `backend = "cpp"` under
## `when defined(windows)`, and `srcDir` under a Nim-version condition. The
## production reader and joiner record each as a conditional entry and
## change nothing else: the shard holding the `defined(windows)` entries
## alone is written in schema 1, as before, and is byte-identical to the
## committed `fixtures/npc_m15_conditional_layout_shard.hex` (written by the
## encoder of reprobuild `36378344d`, before this change), which decodes and
## re-encodes to the same bytes.
##
## The build reads the record through its entries. Planned for Windows, the
## lock's package builds `wintool` with the `cpp` backend, and every module
## is one Nimble installs (`installExt = @["nim"]`). Planned for Linux, it
## builds `tool` with the `c` backend, and the plain `installFiles` leaves
## the other modules uninstalled. The Nim-version `srcDir` is decided at the
## Nim the lock was solved for: `src2` at 2.2.4, `src` at 1.6.20; and a
## build at another Nim than the solved one is refused, naming `srcDir`.
##
## Falsifying mutation (recorded in the plan): reading `backend` from the
## plain field only plans a `c` build for Windows, and fails the test.
##
## No mock: the production reader, codec, lock verbs, fetch and planner.

import std/[os, sequtils, strutils, unittest]

import repro_nimble_reader
import ./nimble_m7_fixtures
import ../../repro_nimble_index/tests/m14_fixtures

const
  FixtureHex = staticRead("../../repro_nimble_index/tests/fixtures/" &
    "npc_m15_conditional_layout_shard.hex").strip()

  WindowsEntriesNimble* = """
version = "1.0.0"
author = "x"
description = "x"
license = "MIT"
srcDir = "src"
bin = @["tool"]
installFiles = @["lib.nim"]

when defined(windows):
  installExt = @["nim"]
  bin = @["wintool"]
  backend = "cpp"
"""

  FullNimble = WindowsEntriesNimble & """

when (NimMajor, NimMinor) >= (2, 0):
  srcDir = "src2"
"""

proc toHex(b: openArray[byte]): string =
  for x in b: result.add toHex(int(x), 2).toLowerAscii()

proc fieldsOf(r: VersionRecord): seq[string] =
  for c in r.layout.conditional: result.add $c.field

proc platformLock(dir, platform: string): string =
  ## The project's lock with its platform replaced by ``platform``.
  let text = readFile(dir / "repro.lock")
  let host = currentPlatformId()
  doAssert host in text, "the lock names no platform " & host
  result = dir / (platform & ".lock")
  writeFile(result, text.replace(host, platform))

suite "NPC-M15: conditional layout and binary entries are applied":
  test "the record holds the entries and the shard keeps its schema and bytes":
    let rec = recordFromNimble("ctool", "v1.0.0", WindowsEntriesNimble)
    check rec.fieldsOf == @["installExt", "bin", "backend"]
    for c in rec.layout.conditional:
      check renderCondition(c.condition) == "defined(windows)"
    # The plain fields are what the file sets outside any `when`.
    check rec.binaries.backend == ""
    check rec.binaries.bin == @["tool"]
    check rec.layout.installExt.len == 0
    check rec.layout.installFiles == @["lib.nim"]
    let bytes = buildShard(0, 0, @[package("ctool", @[rec])], @[])
    let decoded = decodeShard(bytes)
    check shardSchemaOf(decoded) == 1
    check encodeShard(decoded) == bytes
    check toHex(bytes) == FixtureHex
    # The committed bytes decode and re-encode byte-identically.
    var fixture: seq[byte]
    for i in countup(0, FixtureHex.len - 2, 2):
      fixture.add byte(parseHexInt(FixtureHex[i .. i + 1]))
    check encodeShard(decodeShard(fixture)) == fixture
    # The Nim-version `srcDir` is a schema-3 condition, as before.
    let full = recordFromNimble("ctool", "v1.0.0", FullNimble)
    check full.fieldsOf == @["installExt", "bin", "backend", "srcDir"]
    check shardSchemaOf(decodeShard(buildShard(0, 0,
      @[package("ctool", @[full])], @[]))) == 3

  test "a build planned for windows applies the entries; linux the plain fields":
    var w = newWorld("m15-layout")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m15-layout",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let local = parseMirror(mirrorDir)
    var files = @[file("ctool.nimble", FullNimble)]
    for m in ["lib", "tool", "wintool", "legacy"]:
      files.add file("src/" & m & ".nim", "echo \"" & m & "\"\n")
    for m in ["lib", "tool", "wintool", "modern"]:
      files.add file("src2/" & m & ".nim", "echo \"" & m & "\"\n")
    let src = f.package("owner/ctool.git", files)
    local.putSource(src)
    let base = f.recordOf("ctool", src, "v1.0.0")
    let reading = readNimbleSource(FullNimble, "ctool.nimble")
    require reading.isStaticallyReadable
    let rec = recordFromNimbleFile(reading, VersionFacts(tag: "v1.0.0",
      commit: base.commit, tree: base.tree, archiveSha256: base.archiveSha256,
      size: base.size, firstSeen: base.firstSeen, nimbleFile: base.nimbleFile,
      modules: @["legacy", "lib", "tool", "wintool"]))
    discard w.publish(@[f.envelope("ctool", @[rec], src)], daysAgo(1),
      "gen 1", extraFiles = @[("nimble-sources.toml", sourceSetText(@[]))])

    proc prepared(dir, lock: string): NimbleSourcesReport =
      var cfg = f.fetchConfig(w.root / "fetch", @[], store = w.root / "store")
      cfg.useClosureIndex = false
      cfg.mirrors = @[local]
      prepareLockedNimbleSources(dir, lock,
        NimbleSourcesOptions(fetchConfig: some(cfg)))

    let nimAt = "depends: nim >=0.0.0\n\npackage nim\nversions: "
    let dir = w.newProject(@[("ctool", "")], extra = nimAt & "2.2.4\n")
    let locked = refreshProvisioning(dir)
    checkpoint locked.output
    require locked.rc == 0

    # Linux: the plain `bin`, `backend` and install rules.
    let linux = prepared(dir, dir / "repro.lock")
    require linux.packages.len == 1
    check linux.solvedNim == "2.2.4"
    let lp = linux.packages[0]
    # The Nim-version `srcDir` holds at the solved 2.2.4.
    check lp.srcPath.endsWith("src2")
    let lplan = planNimbleBinaries(linux, lp)
    checkpoint lplan.refusal
    check lplan.refusal == ""
    check lplan.backend == "c"
    check lplan.binaries.mapIt(it.name) == @["tool"]
    check lplan.binaries[0].source == lp.srcPath / "tool.nim"
    check binaryArgv(lplan, lplan.binaries[0], "nim", "out", "cache")[1] == "c"
    let lcheck = nimbleCheck(linux)
    checkpoint lcheck.lines.join("\n")
    for m in ["modern", "tool", "wintool"]:
      check ("  module " & m & " is not one Nimble would install") in
        lcheck.lines
    check not lcheck.lines.anyIt("module lib " in it)
    check not lcheck.lines.anyIt("module legacy " in it)

    # Windows: the entries under `defined(windows)`, in record order.
    let windows = prepared(dir, platformLock(dir, "amd64-windows"))
    require windows.packages.len == 1
    check windows.platform == "amd64-windows"
    let wp = windows.packages[0]
    check wp.srcPath.endsWith("src2")
    let wplan = planNimbleBinaries(windows, wp)
    checkpoint wplan.refusal
    check wplan.refusal == ""
    check wplan.backend == "cpp"
    check wplan.binaries.mapIt(it.name) == @["wintool"]
    check wplan.binaries[0].source == wp.srcPath / "wintool.nim"
    check binaryArgv(wplan, wplan.binaries[0], "nim", "out", "cache")[1] ==
      "cpp"
    let wcheck = nimbleCheck(windows)
    checkpoint wcheck.lines.join("\n")
    check not wcheck.lines.anyIt("is not one Nimble would install" in it)
    check wcheck.refused == 0

    # A build whose Nim decides the `srcDir` condition otherwise is refused,
    # naming the field (the NPC-M14 check covers every conditional entry).
    let refused = nimVersionRefusals(linux, "1.6.20")
    checkpoint refused.join("\n")
    check refused.anyIt("(srcDir)" in it and "2.2.4" in it and "1.6.20" in it)
    check nimVersionRefusals(linux, "2.2.4").len == 0

    # Solved at 1.6.20, the same record's `srcDir` is the plain `src`.
    let old = w.newProject(@[("ctool", "")], extra = nimAt & "1.6.20\n")
    let lockedOld = refreshProvisioning(old)
    checkpoint lockedOld.output
    require lockedOld.rc == 0
    let oldReport = prepared(old, old / "repro.lock")
    require oldReport.packages.len == 1
    check oldReport.solvedNim == "1.6.20"
    check oldReport.packages[0].srcPath.endsWith("src")
    check nimbleCheck(oldReport).lines.anyIt(
      "module legacy is not one Nimble would install" in it)

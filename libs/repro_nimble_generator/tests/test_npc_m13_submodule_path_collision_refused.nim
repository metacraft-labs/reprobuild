## NPC-M13 verification `test_npc_m13_submodule_path_collision_refused`
## (threat model G39, T36; spec § 6.1, "Placement and collisions").
##
## * A gitlink placed under an in-tree symbolic link: the origin serves a
##   tree (git's porcelain would not build it, a hostile origin can) holding
##   both a link `lib -> src` and a gitlink `lib/sub`. Placing the
##   submodule's files there would write them through the link. Not
##   offered: no record, and a `gone` event "submodule lib/sub: collision".
## * A placed entry whose path already exists: the origin serves a tree
##   holding both a file `vendor/s/x.c` and a gitlink `vendor/s` whose
##   submodule also has `x.c`. Not offered: "submodule vendor/s: collision"
##   (a later entry never replaces an earlier one).
## * A link inside a submodule that leaves the package
##   (`vendor/s/up -> ../../../outside`): judged against the whole source
##   object, it is out of the tree, so the version is `unreadable` as for
##   any link (the spec's rule): recorded, flagged, never offered, and the
##   diagnostic names the link.
## * A link inside a submodule that points into the superproject
##   (`vendor/s/core -> ../../src/inward.nim`) is in-tree: offered
##   (positive control).
##
## Falsifying mutations: letting a placed entry follow the link writes the
## submodule's files through it and offers the version; letting a later
## entry replace an earlier one offers the duplicate-path version.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./submodule_fixtures

suite "NPC-M13: the source object is checked as one tree":
  test "placement through a link is refused; a link out of the package is unreadable; one into it is in-tree":
    let f = newFixture("m13-collision")
    let work = createTempDir("npc-m13-collision-", "")
    let (_, subCommit) = f.served("nim/sub.git", @[file("sub.c", "int s;\n")])
    # A: a link `lib` and a gitlink `lib/sub` in one crafted tree.
    let nimbleA = nimbleFile("throughlink")
    let a = f.craftedCommit("nim/throughlink.git", @[
      blob(nimbleA.path, nimbleA.content),
      blob("src/throughlink.nim", "discard\n"),
      blob(".gitmodules", gitmodules(@[("lib/sub",
        f.url("nim/sub.git"))]).content),
      linkBlob("lib", "src"),
      gitlinkEntry("lib/sub", subCommit)], "v1.0.0")
    # D: a file and a placed submodule entry at one path.
    let (_, dupCommit) = f.served("nim/dup-sub.git", @[
      file("x.c", "int theirs;\n")])
    let nimbleD = nimbleFile("duplicate")
    let d = f.craftedCommit("nim/duplicate.git", @[
      blob(nimbleD.path, nimbleD.content),
      blob("src/duplicate.nim", "discard\n"),
      blob(".gitmodules", gitmodules(@[("vendor/s",
        f.url("nim/dup-sub.git"))]).content),
      blob("vendor/s/x.c", "int ours;\n"),
      gitlinkEntry("vendor/s", dupCommit)], "v1.0.0")
    # B: a submodule whose link leaves the package.
    let (_, outCommit) = f.served("nim/outward-sub.git", @[
      file("x.c", "int x;\n"), symlink("up", "../../../outside")])
    discard f.served("nim/outward.git", @[nimbleFile("outward"),
      file("src/outward.nim", "discard\n"),
      gitmodules(@[("vendor/s", f.url("nim/outward-sub.git"))]),
      gitlinkTo("vendor/s", outCommit)], tags = @["v1.0.0"])
    # C: a submodule whose link points into the superproject.
    let (_, inCommit) = f.served("nim/inward-sub.git", @[
      file("y.c", "int y;\n"), symlink("core", "../../src/inward.nim")])
    discard f.served("nim/inward.git", @[nimbleFile("inward"),
      file("src/inward.nim", "discard\n"),
      gitmodules(@[("vendor/s", f.url("nim/inward-sub.git"))]),
      gitlinkTo("vendor/s", inCommit)], tags = @["v1.0.0"])
    let reg = f.registryOf(@[("throughlink", f.url("nim/throughlink.git")),
      ("duplicate", f.url("nim/duplicate.git")),
      ("outward", f.url("nim/outward.git")),
      ("inward", f.url("nim/inward.git"))])
    let g = f.generation(reg, 1_790_000_000, work / "state")
    checkpoint "events: " & $g.events
    checkpoint "diagnostics: " & g.diagnostics.join("\n")

    # A: not offered, one event naming the submodule and the collision.
    check not g.built.hasPackage("throughlink")
    let gone = g.goneOf("throughlink")
    check gone.len == 1
    if gone.len == 1:
      check gone[0].before == a
      check gone[0].after == "submodule lib/sub: collision"

    # D: not offered, one event naming the submodule and the collision.
    check not g.built.hasPackage("duplicate")
    let goneD = g.goneOf("duplicate")
    check goneD.len == 1
    if goneD.len == 1:
      check goneD[0].before == d
      check goneD[0].after == "submodule vendor/s: collision"

    # B: recorded unreadable (the link is out of the WHOLE tree), not
    # offered, and the diagnostic names the link.
    let rb = g.built.recordOf("outward", "v1.0.0")
    require rb.isSome
    check flUnreadable in rb.get.flags
    check rb.get.submodules.len == 1
    check g.built.offeredTags("outward").len == 0
    check exUnreadable in g.built.exclusionsOf("outward", "v1.0.0")
    var named = false
    for d in g.diagnostics:
      if "outward@v1.0.0" in d and "vendor/s/up" in d and
          "points outside the tree" in d:
        named = true
    check named
    check g.goneOf("outward").len == 0

    # C: in-tree, offered.
    let rc = g.built.recordOf("inward", "v1.0.0")
    require rc.isSome
    check flUnreadable notin rc.get.flags
    check g.built.offeredTags("inward") == @["v1.0.0"]

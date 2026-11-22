## NPC-M10 verification `test_npc_m10_ini_nimble_read_as_data` (A2;
## NPC-AREQ8 step 1).
##
## A package whose `.nimble` is in the old INI format (`[Package]`, `[Deps]`
## with `Requires: "a >= 1.0, b"`) gets a record with those two
## requirements and no `unreadable` flag, through the generator's `read`
## edge -- the production path, origins served over the fixture's TLS
## listener. One with an unknown INI key, which Nimble itself refuses, is
## `unreadable`. A NimScript `.nimble` beside them is read as before.
##
## Falsifying mutation (recorded in the plan): leaving `admitIniFormat` at
## its default makes the record needs-probe and unreadable, and fails the
## test.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./generator_fixtures

const
  Now = 1_790_000_000'u64
  IniNimble = """[Package]
name          = "inipkg"
version       = "0.3.0"
author        = "x"
description   = "an old-format package"
license       = "MIT"
srcDir        = "src"

[Deps]
Requires: "a >= 1.0, b"
"""
  BadIniNimble = """[Package]
name          = "inibad"
version       = "0.1.0"
author        = "x"
description   = "an old-format package with a key Nimble refuses"
license       = "MIT"
colour        = "blue"

[Deps]
Requires: "a"
"""

suite "NPC-M10: an INI-format .nimble is read as data":

  test "[Deps] Requires gives two requirements and no unreadable flag; an unknown key is unreadable":
    let f = newFixture("m10-ini")
    let ini = f.newRepo("nim/inipkg.git")
    discard ini.commit(@[file("inipkg.nimble", IniNimble),
      file("src/inipkg.nim", "discard\n")])
    ini.tag("v0.3.0")
    ini.publish()
    let bad = f.newRepo("nim/inibad.git")
    discard bad.commit(@[file("inibad.nimble", BadIniNimble),
      file("inibad.nim", "discard\n")])
    bad.tag("v0.1.0")
    bad.publish()
    let script = f.newRepo("nim/script.git")
    discard script.commit(@[nimbleFile("script", @["a >= 2.0"]),
      file("src/script.nim", "discard\n")])
    script.tag("v1.0.0")
    script.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("inipkg", f.url("nim/inipkg.git")),
      ("inibad", f.url("nim/inibad.git")),
      ("script", f.url("nim/script.git"))])])
    reg.publish()
    let work = createTempDir("npc-m10-ini-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit), "s.toml"), Now,
      work / "state", outputDir = work / "index"))
    checkpoint g.diagnostics.join("\n")

    let r = g.built.envelopeOf("inipkg").versions[0]
    check r.version.tag == "v0.3.0"
    check flUnreadable notin r.flags
    check r.readerClass == rrcPlain
    check r.nimbleFile.isSome
    check r.requires.len == 2
    if r.requires.len == 2:
      check r.requires[0].target == "a"
      check r.requires[0].versionKind == rvRange
      check r.requires[0].constraint == ">= 1.0.0"
      check r.requires[1].target == "b"
      check r.requires[1].versionKind == rvAny
    check r.layout.srcDir == "src"
    check r.layout.modules == @["inipkg"]

    let b = g.built.envelopeOf("inibad").versions[0]
    check flUnreadable in b.flags
    check b.readerClass == rrcUnreadable

    # A NimScript file is read as before.
    let s = g.built.envelopeOf("script").versions[0]
    check flUnreadable notin s.flags
    check s.requires.len == 1

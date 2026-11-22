## NPC-M13 verification `test_npc_m13_unobtainable_submodule_not_offered`
## (spec § 6.1, "What is not offered"; NPC-AREQ31 item 1).
##
## Three packages, each with one gitlink that cannot be obtained:
##
## * `noentry`: the gitlink has no `.gitmodules` entry;
## * `goneorigin`: its `.gitmodules` URL names a repository the forge does
##   not serve (yet);
## * `nocommit`: its URL serves a repository that does not hold the pinned
##   commit (yet: the commit exists only in an unpublished work tree).
##
## Generation 1: none has a record, each has exactly one `gone` event naming
## the submodule and the reason. Then the two origins are fixed: the missing
## repository is created and the missing commit pushed. Generation 2 runs
## their `submodule` edges again (a failed answer is not reused from the
## cache) and offers both; `noentry` stays unoffered, without a second
## event. A third generation on a host without this host's cache gives the
## same root (positive control for the retry).
##
## Falsifying mutation: recording the version with the superproject tree
## when a submodule fails offers an incomplete source.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./submodule_fixtures

suite "NPC-M13: a version whose submodule cannot be obtained is not offered":
  test "no entry, origin gone, commit absent: no record, one event each; retried and offered once the submodule answers":
    let f = newFixture("m13-unobtainable")
    let work = createTempDir("npc-m13-unobtainable-", "")
    let (_, present) = f.served("nim/present.git", @[file("p.c", "int p;\n")])
    # A submodule commit that its origin does not hold yet.
    let late = f.newRepo("nim/late.git")
    discard late.commit(@[file("l.c", "int l0;\n")])
    late.publish()
    let unpublished = late.commit(@[file("l.c", "int l1;\n")])
    # A submodule repository the forge does not serve yet.
    let absentUrl = f.url("nim/absent.git")
    discard f.served("nim/noentry.git", @[nimbleFile("noentry"),
      file("src/noentry.nim", "discard\n"),
      gitmodules(@[("vendor/other", f.url("nim/present.git"))]),
      gitlinkTo("vendor/x", present)], tags = @["v1.0.0"])
    discard f.served("nim/goneorigin.git", @[nimbleFile("goneorigin"),
      file("src/goneorigin.nim", "discard\n"),
      gitmodules(@[("vendor/x", absentUrl)]),
      gitlinkTo("vendor/x", present)], tags = @["v1.0.0"])
    discard f.served("nim/nocommit.git", @[nimbleFile("nocommit"),
      file("src/nocommit.nim", "discard\n"),
      gitmodules(@[("vendor/x", f.url("nim/late.git"))]),
      gitlinkTo("vendor/x", unpublished)], tags = @["v1.0.0"])
    let reg = f.registryOf(@[("noentry", f.url("nim/noentry.git")),
      ("goneorigin", f.url("nim/goneorigin.git")),
      ("nocommit", f.url("nim/nocommit.git"))])

    let g1 = f.generation(reg, 1_790_000_000, work / "state",
      outputDir = work / "gen1")
    checkpoint "g1 events: " & $g1.events
    checkpoint "g1 diagnostics: " & g1.diagnostics.join("\n")
    for (name, phrase) in [("noentry", "no .gitmodules entry"),
                           ("goneorigin", "the origin does not answer"),
                           ("nocommit", "the origin does not hold the commit")]:
      check not g1.built.hasPackage(name)
      let gone = g1.goneOf(name)
      check gone.len == 1
      if gone.len == 1:
        check gone[0].version == "v1.0.0"
        check gone[0].after == "submodule vendor/x: " & phrase
    check g1.events.len == 3

    # The two origins are fixed.
    discard f.served("nim/absent.git", @[file("a.c", "int a;\n")])
    let fixed = f.root / "nim/absent.git"
    check dirExists(fixed)
    # `served` committed a new tree; the gitlink pins `present`'s commit,
    # which the new repository must hold: push it there too.
    discard run(["git", "--git-dir=" & fixed, "fetch", "-q",
      f.root / "nim/present.git", present & ":refs/heads/pinned"],
      env = gitEnv())
    late.publish()

    let g2 = f.generation(reg, 1_790_086_400, work / "state",
      previous = work / "gen1", outputDir = work / "gen2")
    checkpoint "g2 events: " & $g2.events
    checkpoint "g2 executed: " & $g2.executed
    var refetched: seq[string]
    for s in g2.executedOf(efSubmodule): refetched.add s
    check (absentUrl & "@" & present) in refetched
    check (f.url("nim/late.git") & "@" & unpublished) in refetched
    check g2.built.offeredTags("goneorigin") == @["v1.0.0"]
    check g2.built.offeredTags("nocommit") == @["v1.0.0"]
    let rl = g2.built.recordOf("nocommit", "v1.0.0")
    require rl.isSome
    check rl.get.submodules == @[RecordSubmodule(path: "vendor/x",
      url: f.url("nim/late.git"), commit: unpublished)]
    check not g2.built.hasPackage("noentry")
    check g2.goneOf("noentry").len == 0
    check g2.events.len == 0

    # The same generation without this host's cache: the same root.
    let other = f.generation(reg, 1_790_086_400, work / "state-other",
      previous = work / "gen1")
    check other.built.rootId == g2.built.rootId

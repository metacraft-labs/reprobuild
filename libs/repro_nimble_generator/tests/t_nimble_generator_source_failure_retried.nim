## A version whose source cannot be fetched (NPC-AREQ31 item 1, spec § 3):
##
##   * it gets no record and one `gone` event, at the generation that first
##     admits it, and no second event while it stays unfetchable;
##   * its failed answer is not served from this host's cache: the `source`
##     edge runs again at the next generation, so once the origin serves the
##     commit the version is recorded, and the root is the one a host
##     without that cache generates from the same inputs.
##
## The origin lists its refs throughout and answers 503 to object requests
## while a flag file exists. Falsifying mutations: reusing the cached failed
## answer leaves the version unrecorded after the origin recovers (and the
## two hosts' roots differ); dropping the "reported once" rule repeats the
## event at the second generation.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

proc count(r: GenerationResult; family: EdgeFamily; subject = ""): int =
  for e in r.executed:
    if e.family == family and e.subject.startsWith(subject): inc result

suite "NPC-M4: an unfetchable source is retried and reported once":

  test "a failing source: one gone event, retried, recorded once it is served":
    let flag = createTempDir("npc-m4-flaky-flag-", "") / "failing"
    writeFile(flag, "")
    let f = newFixture("flaky", @[Route(prefix: "/nim/flaky.git/",
      failFetchWhile: flag)])
    let flaky = f.newRepo("nim/flaky.git")
    discard flaky.commit(@[nimbleFile("flaky"), file("src/flaky.nim",
      "discard\n")])
    flaky.tag("v1.0.0")
    flaky.publish()
    let steady = f.newRepo("nim/steady.git")
    discard steady.commit(@[nimbleFile("steady"), file("src/steady.nim",
      "discard\n")])
    steady.tag("v1.0.0")
    steady.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("flaky", f.url("nim/flaky.git")), ("steady", f.url("nim/steady.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit), "s.toml")
    let work = createTempDir("npc-m4-flaky-run-", "")

    proc goneOf(r: GenerationResult; pkg: string): int =
      for e in r.events:
        if e.kind == oeGone and e.package == pkg: inc result

    # Generation 1: the refs answer, the objects do not.
    let g1 = generate(f.genConfig(ss, 1_790_000_000, work / "state",
      outputDir = work / "gen1"))
    checkpoint "g1 events: " & $g1.events
    check g1.built.observationOf("flaky").state == osAnswering
    check g1.built.envelopeOf("steady").versions.len == 1
    check not g1.built.hasPackage("flaky")
    check g1.goneOf("flaky") == 1
    check g1.count(efSource, "flaky@") == 1

    # Generation 2: still failing. The edge runs again; no second event.
    let g2 = generate(f.genConfig(ss, 1_790_086_400, work / "state",
      previous = work / "gen1", outputDir = work / "gen2"))
    checkpoint "g2 events: " & $g2.events
    check g2.count(efSource, "flaky@") == 1
    check not g2.built.hasPackage("flaky")
    check g2.goneOf("flaky") == 0
    check g2.events.len == 0

    # Generation 3: the origin serves the commit again.
    removeFile(flag)
    let g3 = generate(f.genConfig(ss, 1_790_172_800, work / "state",
      previous = work / "gen2", outputDir = work / "gen3"))
    checkpoint "g3 executed: " & $g3.executed
    check g3.count(efSource, "flaky@") == 1
    check g3.built.hasPackage("flaky")
    if g3.built.hasPackage("flaky"):
      check g3.built.envelopeOf("flaky").versions.len == 1
    check g3.goneOf("flaky") == 0
    # The same generation on a host without this host's cache.
    let other = generate(f.genConfig(ss, 1_790_172_800, work / "state-other",
      previous = work / "gen2"))
    check other.built.rootId == g3.built.rootId

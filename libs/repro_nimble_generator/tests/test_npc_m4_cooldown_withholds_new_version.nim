## NPC-M4 verification `test_npc_m4_cooldown_withholds_new_version`
## (NPC-AREQ11, threat model G8): a version first seen yesterday is absent
## from the index under `cooldown_days = 7`.
##
## The tag and its commit are back-dated 30 days, as an origin can: the
## dates in a repository are the author's word. `first_seen` is the
## generator's own observation, so the back-dating buys nothing.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

const
  Day = 86_400'u64
  Today = 1_790_000_000'u64

suite "NPC-M4: cooldown_days withholds a version from first sighting":

  test "a back-dated tag first seen yesterday is absent under cooldown_days = 7":
    let f = newFixture("cooldown")
    let old = f.newRepo("nim/steady.git")
    discard old.commit(@[nimbleFile("steady"), file("src/steady.nim", "discard\n")],
      date = int64(Today - 400 * Day))
    old.tag("v1.0.0", date = int64(Today - 400 * Day))
    old.publish()
    let fresh = f.newRepo("nim/fresh.git")
    discard fresh.commit(@[nimbleFile("fresh"), file("src/fresh.nim", "discard\n")],
      date = int64(Today - 30 * Day))
    fresh.tag("v1.0.0", date = int64(Today - 30 * Day))
    fresh.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("steady", f.url("nim/steady.git"))])])
    let regCommit2 = reg.commit(@[packagesJson(@[
      ("steady", f.url("nim/steady.git")), ("fresh", f.url("nim/fresh.git"))])])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let policy = "\n[policy]\ncooldown_days = 7\n"
    let work = createTempDir("npc-m4-cooldown-run-", "")

    # Eight days ago: `steady` is sighted, and admitted after its cooldown.
    let g0 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl,
      regCommit, policy), "s.toml"), Today - 8 * Day, work / "state",
      outputDir = work / "g0"))
    check not g0.built.hasPackage("steady") # held on its first sighting
    check g0.built.observationOf("steady").held.len == 1
    # Yesterday: the registry lists `fresh`, whose tag is 30 days old.
    let g1 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl,
      regCommit2, policy), "s.toml"), Today - Day, work / "state",
      previous = work / "g0", outputDir = work / "g1"))
    check g1.built.hasPackage("steady")
    check g1.built.envelopeOf("steady").versions[0].firstSeen == Today - 8 * Day
    check not g1.built.hasPackage("fresh")
    let held = g1.built.observationOf("fresh").held
    check held.len == 1
    check held[0].version.tag == "v1.0.0"
    check held[0].firstSeen == Today - Day

    # Today: first seen yesterday, so still absent.
    let g2 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl,
      regCommit2, policy), "s.toml"), Today, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    check not g2.built.hasPackage("fresh")
    check g2.built.observationOf("fresh").held[0].firstSeen == Today - Day
    # A generation without a previous index sees it for the first time now,
    # back-dated or not.
    let g2cold = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl,
      regCommit2, policy), "s.toml"), Today, work / "state-cold"))
    check not g2cold.built.hasPackage("fresh")

    # Six days later it has been observable for seven: admitted, with the
    # first sighting as its `first_seen`.
    let g3 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl,
      regCommit2, policy), "s.toml"), Today + 6 * Day, work / "state",
      previous = work / "g2", outputDir = work / "g3"))
    check g3.built.hasPackage("fresh")
    let rec = g3.built.envelopeOf("fresh").versions[0]
    check rec.firstSeen == Today - Day
    check rec.version.tag == "v1.0.0"
    check g3.built.observationOf("fresh").held.len == 0

    # Positive control: without a cooldown the same tag is in the index on
    # its first sighting.
    let g4 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl,
      regCommit2), "s.toml"), Today, work / "state-nocooldown"))
    check g4.built.hasPackage("fresh")

## NPC-M10 verification `test_npc_m10_independent_regeneration_mismatch_alerts`
## (threat model G9, DET-1).
##
## A publisher publishes an index in which one version record's tree digest
## is substituted (every other byte as the honest generation gives it, the
## root re-derived, so the index is self-consistent). The independent
## regeneration, with its own state directory, repeats the generation from
## the inputs the index names and finds an unexplained difference in that
## record: it alerts (a `regeneration-mismatch` detection in the evidence
## sink, naming the package and both digests) and holds the next publish,
## which the generator then refuses on top of that root.
##
## Second, the honest index is regenerated after an origin moved a tag: the
## differences are explained, reported as that origin change, nothing is
## held, and the publish on top goes through. A forged record of the same
## version and commit stays unexplained even beside a forged origin change
## of its package.
##
## Falsifying mutation (recorded in the plan): a regeneration job that
## compares only record counts misses the substituted digest, and fails the
## test.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures
import ../../repro_nimble_fetch/tests/npc_sink_fixtures

const Now = 1_790_000_000'u64

proc idOfHex(hex: string): IndexObjectId =
  for i in 0 ..< 32:
    result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc substituted(b: BuiltIndex; package: string; tree: string): BuiltIndex =
  ## ``b`` with ``package``'s first record's tree digest replaced, the root
  ## re-derived from the result.
  var input = IndexBuildInput(generator: b.root.generator,
    sourceSet: b.root.sourceSet, generatedAt: b.root.generatedAt,
    previousRoot: b.root.previousRoot, shardBits: int(b.root.shardBits))
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  for r in idx.root.shards:
    let s = idx.loadShard(r.bucket)
    if s.isNone: continue
    for p in s.get.packages:
      var q = p
      if p.name == package:
        q.versions[0].tree = idOfHex(tree)
      input.packages.add q
    input.aliases.add s.get.aliases
    input.observations.add s.get.observations
  input.events = idx.loadEvents().events
  buildIndex(input)

suite "NPC-M10: the independent regeneration catches a substituted digest":

  test "an unexplained difference alerts and holds; an origin change is explained":
    let f = newFixture("m10-regen")
    let victim = f.newRepo("nim/victim.git")
    discard victim.commit(@[nimbleFile("victim"),
      file("src/victim.nim", "discard\n")])
    victim.tag("v1.0.0")
    victim.publish()
    let mover = f.newRepo("nim/mover.git")
    discard mover.commit(@[nimbleFile("mover"),
      file("src/mover.nim", "discard\n")])
    mover.tag("v1.0.0")
    mover.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("victim", f.url("nim/victim.git")), ("mover", f.url("nim/mover.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit), "s.toml")
    let work = createTempDir("npc-m10-regen-", "")
    let honest = generate(f.genConfig(ss, Now, work / "publisher-state",
      outputDir = work / "honest"))

    # The publisher's substituted index.
    let forgedTree = repeat("ab", 32)
    let forged = substituted(honest.built, "victim", forgedTree)
    check forged.rootId != honest.built.rootId
    writeIndexDir(forged, work / "forged")

    var s = startNpcSink("npc-m10-regen-sink")
    defer: s.stop()
    let app = s.appender()
    app.registerDetector(RegenerationDetectorName, 60_000, probed = true)

    let c = runRegeneration(work / "forged", ss, "", work / "regen-state",
      f.genConfig(ss, Now, ""))
    checkpoint $c.unexplained
    check c.verdict == rvUnexplained
    var victimDigest = false
    for d in c.unexplained:
      if d.package == "victim" and forgedTree in d.published: victimDigest = true
    check victimDigest
    let hold = work / "publish-hold"
    if c.verdict == rvUnexplained: holdPublish(hold, c)
    reportRegeneration(c, app)
    check app.drain()
    let alerts = s.sink.detections("regeneration-mismatch")
    check alerts.len >= 1
    var named = false
    for a in alerts:
      if a.record.field("package") == "victim" and
          forgedTree in a.record.field("digest"):
        named = true
    check named
    check s.heartbeats(RegenerationDetectorName).len == 1

    # The next publish on top of the forged root is held.
    var next = f.genConfig(ss, Now + 86400, work / "publisher-state",
      previous = work / "forged", outputDir = work / "next")
    next.publishHold = hold
    expect GeneratorError:
      discard generate(next)
    check not fileExists(work / "next" / IndexRootFile)

    # An origin change between publish and regeneration is explained.
    discard mover.commit(@[nimbleFile("mover"),
      file("src/mover.nim", "echo 2\n")], date = 1_700_500_000)
    mover.tag("v1.0.0")
    mover.publish()
    let e = runRegeneration(work / "honest", ss, "", work / "regen-state-2",
      f.genConfig(ss, Now, ""))
    checkpoint $e.explained
    check e.verdict == rvExplained
    check e.unexplained.len == 0
    var moverChange = false
    for x in e.explained:
      if x.difference.package == "mover" and "origin tag v1.0.0" in x.change:
        moverChange = true
    check moverChange
    # A publisher that also forges the victim's observation (so that its
    # origin seems to have changed) is not explained by it: the record of
    # the same version and commit still differs.
    var both = c.unexplained
    both.add IndexDifference(package: "victim", field: "origin tag v1.0.0",
      published: repeat("1", 40), repeated: repeat("2", 40))
    let forgedBoth = classify(c.publishedRoot, c.repeatedRoot, both)
    check forgedBoth.verdict == rvUnexplained
    var stillNamed = false
    for d in forgedBoth.unexplained:
      if d.package == "victim" and forgedTree in d.published:
        stillNamed = true
    check stillNamed

    # Nothing held: the publish on top of the honest root goes through.
    var onTop = f.genConfig(ss, Now + 86400, work / "publisher-state",
      previous = work / "honest", outputDir = work / "on-top")
    onTop.publishHold = work / "no-hold"
    discard generate(onTop)
    check fileExists(work / "on-top" / IndexRootFile)
    app.close()

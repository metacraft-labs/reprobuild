## NPC-M4 verification `test_npc_m4_warm_run_rereads_only_changed`
## (NPC-AREQ10): a generation after one upstream tag changed re-reads that
## package only.
##
## `refs` is the one edge revalidated against every origin each generation
## -- it is how the generator learns that a tag changed at all -- so it runs
## for every package. What the warm generation must not repeat is the work
## behind it: the `source` and `read` edges run only for the changed
## package's new commit, and the `shard` edges only for the shard that
## package is in; every other shard is a cache hit.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

proc count(r: GenerationResult; family: EdgeFamily): int =
  for e in r.executed:
    if e.family == family: inc result

proc subjects(r: GenerationResult; family: EdgeFamily): seq[string] =
  for e in r.executed:
    if e.family == family: result.add e.subject

suite "NPC-M4: a warm generation re-reads only what changed":

  test "one moved-on package: refs for all, source and read for it only, one shard":
    let f = newFixture("warm")
    var entries: seq[(string, string)]
    var works: seq[string]
    for i in 0 ..< 12:
      let name = "pkg" & $i
      let w = f.newRepo("nim/" & name & ".git")
      discard w.commit(@[nimbleFile(name), file("src/" & name & ".nim",
        "discard\n")])
      w.tag("v1.0.0")
      discard w.commit(@[nimbleFile(name, @["pkg0"]), file("src/" & name &
        ".nim", "echo 1\n")], date = 1_700_100_000)
      w.tag("v1.1.0")
      w.publish()
      entries.add (name, f.url("nim/" & name & ".git"))
      works.add w
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(entries)])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
      regCommit), "s.toml")
    let work = createTempDir("npc-m4-warm-run-", "")
    var cfg = f.genConfig(ss, 1_790_000_000, work / "state",
      outputDir = work / "gen1")
    cfg.shardBits = 3
    let cold = generate(cfg)
    check cold.count(efRefs) == 12
    check cold.count(efSource) == 24
    check cold.count(efRead) == 24
    let shardsCold = cold.count(efShard)
    check shardsCold == cold.built.root.shards.len
    check shardsCold > 2  # several shards, so "only one" is a real claim

    # A generation with nothing changed upstream re-reads nothing.
    var steadyCfg = f.genConfig(ss, 1_790_043_200, work / "state",
      previous = work / "gen1", outputDir = work / "gen1b")
    steadyCfg.shardBits = 3
    let steady = generate(steadyCfg)
    check steady.count(efRefs) == 12
    check steady.count(efSource) == 0
    check steady.count(efRead) == 0
    check steady.events.len == 0

    # One upstream change: pkg7 gets a new tag on a new commit.
    discard works[7].commit(@[nimbleFile("pkg7", @["pkg0 >= 1.1.0"]),
      file("src/pkg7.nim", "echo 2\n")], date = 1_700_200_000)
    works[7].tag("v1.2.0")
    works[7].publish()

    var warmCfg = f.genConfig(ss, 1_790_086_400, work / "state",
      previous = work / "gen1b", outputDir = work / "gen2")
    warmCfg.shardBits = 3
    let warm = generate(warmCfg)
    checkpoint "executed: " & $warm.executed
    # refs: revalidated for every package.
    check warm.count(efRefs) == 12
    # The changed package alone is re-read.
    check warm.subjects(efSource).len == 1
    check warm.subjects(efSource)[0].startsWith("pkg7@")
    check warm.count(efRead) == 1
    for s in warm.subjects(efHistory):
      check s.startsWith("pkg7 ")
    # Only pkg7's shard is recomputed; the others are cache hits.
    check warm.count(efShard) == 1
    check warm.subjects(efShard)[0] ==
      $shardBucket(nameKey("pkg7"), 3)
    check warm.count(efRoot) == 1
    # The registry edge is keyed by its pinned commit: a cache hit.
    check warm.count(efRegistry) == 0
    # And the result is what a cold generation from the same inputs gives.
    check warm.built.envelopeOf("pkg7").versions.len == 3
    var coldAgainCfg = f.genConfig(ss, 1_790_086_400, work / "state-cold",
      previous = work / "gen1b")
    coldAgainCfg.shardBits = 3
    let coldAgain = generate(coldAgainCfg)
    check coldAgain.built.rootId == warm.built.rootId
    check coldAgain.count(efSource) == 1 # still keyed by the previous index

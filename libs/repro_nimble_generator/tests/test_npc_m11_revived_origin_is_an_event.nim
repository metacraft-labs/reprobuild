## NPC-M11 adversarial audit (threat model T8, G31; NPC-AREQ4): a gone
## origin that answers again with other history is an origin event.
##
## The repo-jacking shape: `victim`'s repository is deleted, one generation
## records it `gone`, and then someone re-creates the repository under the
## same name with unrelated history, re-using the recorded tag `v1.0.0` for
## another commit and adding `v1.0.1`. NPC-AREQ4's table defines
## `tag-moved` as "a tag recorded for a version now names another commit"
## and `history-rewritten` as "a recorded commit is no longer reachable
## from the origin's branches". Before this audit the generation that saw
## the origin again recorded neither: the previous observation (`gone`)
## listed no tag and no `HEAD`, so there was nothing to compare with, and
## the attacker's versions entered the index with no event beside them.
##
## Now that generation records `tag-moved` for `v1.0.0` (recorded commit ->
## the new one) and `history-rewritten` for the recorded commit, and the old
## record is byte-identical. An origin that comes back after an outage with
## its history intact records no event (control), and one re-created
## between two generations, with no `gone` in between, records the same
## two events as before (the existing path, unchanged).
##
## A benign revival records nothing either when the recorded commit is on
## no branch: a tag cut from a branch that was deleted (or rewritten) long
## before. With no earlier answer to compare with, only a recorded commit
## the origin no longer holds at all is `history-rewritten`.
##
## Falsifying mutations: without the comparison against the records after a
## non-answering observation there is no `tag-moved`; without the history
## edge on revival there is no `history-rewritten`; reporting every recorded
## commit no branch reaches reports the benign revival.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./generator_fixtures

const
  Day = 86_400'u64
  T1 = 1_790_000_000'u64

proc kinds(g: GenerationResult): seq[string] =
  for e in g.events:
    result.add $e.kind & " " & e.package & " " & e.version & " " & e.before &
      " -> " & e.after

suite "NPC-M11: a gone origin that comes back with other history is an event":

  test "re-registered after a gone generation: tag-moved and history-rewritten, records unchanged":
    let f = newFixture("m11-revived")
    let repo = f.newRepo("nim/victim.git")
    let c1 = repo.commit(@[nimbleFile("victim"),
      file("src/victim.nim", "proc v*(): int = 1\n")])
    repo.tag("v1.0.0")
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("victim", f.url("nim/victim.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"), rc),
      "s.toml")
    let work = createTempDir("npc-m11-revived-", "")
    let g1 = generate(f.genConfig(ss, T1, work / "state",
      outputDir = work / "g1"))
    let original = recordBytes(g1.built.envelopeOf("victim").versions[0])
    # Keep the served repository to put back for the outage control.
    copyDir(f.root / "nim/victim.git", work / "victim-saved.git")

    f.deleteServed("nim/victim.git")
    let g2 = generate(f.genConfig(ss, T1 + Day, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    check kinds(g2) == @["gone victim  answering -> no answer"]

    # Someone else's repository at the same URL.
    let jack = f.newRepo("jack/victim.git")
    let j1 = jack.commit(@[nimbleFile("victim"),
      file("src/victim.nim", "proc v*(): int = 666\n")], date = 1_700_100_000)
    jack.tag("v1.0.0")
    discard jack.commit(@[nimbleFile("victim"),
      file("src/victim.nim", "proc v*(): int = 667\n")], date = 1_700_200_000)
    jack.tag("v1.0.1")
    jack.publish()
    moveDir(f.root / "jack/victim.git", f.root / "nim/victim.git")
    let g3 = generate(f.genConfig(ss, T1 + 2 * Day, work / "state",
      previous = work / "g2", outputDir = work / "g3"))
    checkpoint kinds(g3).join("\n")
    check ("tag-moved victim v1.0.0 " & c1 & " -> " & j1) in kinds(g3)
    check ("history-rewritten victim v1.0.0 " & c1 & " -> ") in kinds(g3)
    check g3.events.len == 2
    for e in g3.events: check e.observedAt == T1 + 2 * Day
    var old = 0
    for v in g3.built.envelopeOf("victim").versions:
      if v.commit == c1:
        inc old
        check recordBytes(v) == original
    check old == 1

    # Control: an outage. The same repository comes back; no event.
    let w2 = createTempDir("npc-m11-outage-", "")
    removeDir(f.root / "nim/victim.git")
    copyDir(work / "victim-saved.git", f.root / "nim/victim.git")
    let o1 = generate(f.genConfig(ss, T1, w2 / "state", outputDir = w2 / "o1"))
    check o1.events.len == 0
    removeDir(f.root / "nim/victim.git")
    let o2 = generate(f.genConfig(ss, T1 + Day, w2 / "state",
      previous = w2 / "o1", outputDir = w2 / "o2"))
    check kinds(o2) == @["gone victim  answering -> no answer"]
    copyDir(work / "victim-saved.git", f.root / "nim/victim.git")
    let o3 = generate(f.genConfig(ss, T1 + 2 * Day, w2 / "state",
      previous = w2 / "o2", outputDir = w2 / "o3"))
    checkpoint kinds(o3).join("\n")
    check o3.events.len == 0
    check o3.built.envelopeOf("victim").versions.len == 1

    # The existing path: re-created between two generations, no `gone`.
    removeDir(f.root / "nim/victim.git")
    let jack2 = f.newRepo("jack2/victim.git")
    let k1 = jack2.commit(@[nimbleFile("victim"),
      file("src/victim.nim", "proc v*(): int = 668\n")], date = 1_700_300_000)
    jack2.tag("v1.0.0")
    jack2.publish()
    moveDir(f.root / "jack2/victim.git", f.root / "nim/victim.git")
    let w3 = createTempDir("npc-m11-direct-", "")
    let d3 = generate(f.genConfig(ss, T1 + 2 * Day, w3 / "state",
      previous = work / "g1", outputDir = w3 / "d3"))
    checkpoint kinds(d3).join("\n")
    check ("tag-moved victim v1.0.0 " & c1 & " -> " & k1) in kinds(d3)
    check ("history-rewritten victim v1.0.0 " & c1 & " -> ") in kinds(d3)

  test "a recorded commit only a tag holds comes back after an outage: no event":
    let f = newFixture("m11-revived-tagonly")
    let repo = f.newRepo("nim/lib.git")
    discard repo.commit(@[nimbleFile("lib"),
      file("src/lib.nim", "proc v*(): int = 1\n")])
    repo.tag("v1.0.0")
    # `main` rewritten before the package was ever indexed: the tag holds
    # the only path to its commit.
    discard git(repo, "checkout", "-q", "--orphan", "rewritten")
    discard repo.commit(@[nimbleFile("lib"),
      file("src/lib.nim", "proc v*(): int = 2\n")], date = 1_700_300_000)
    discard git(repo, "branch", "-M", "rewritten", "main")
    repo.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("lib", f.url("nim/lib.git"))])])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"), rc),
      "s.toml")
    let work = createTempDir("npc-m11-tagonly-", "")
    let g1 = generate(f.genConfig(ss, T1, work / "state",
      outputDir = work / "g1"))
    check g1.built.envelopeOf("lib").versions.len == 1
    copyDir(f.root / "nim/lib.git", work / "lib-saved.git")
    removeDir(f.root / "nim/lib.git")
    let g2 = generate(f.genConfig(ss, T1 + Day, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    check kinds(g2) == @["gone lib  answering -> no answer"]
    copyDir(work / "lib-saved.git", f.root / "nim/lib.git")
    let g3 = generate(f.genConfig(ss, T1 + 2 * Day, work / "state",
      previous = work / "g2", outputDir = work / "g3"))
    checkpoint kinds(g3).join("\n")
    check g3.events.len == 0
    check g3.built.envelopeOf("lib").versions.len == 1

## NPC-M11 adversarial audit (threat model T4, G31; NPC-AREQ31 item 1): a
## package whose origin passes a bound of the index format does not stop
## the generation.
##
## The index format bounds every list (spec § 4.4: 4096 versions and
## observed tags per package, 1024 top-level modules, 512 requirements, 256
## binaries, 64 foreign dependencies, ...). An author controls all of them:
## a `.nimble` with 600 `requires`, a `src/` with 1100 modules, 4100 tags
## pushed at one commit. Before this audit any one of these failed the
## `read` or `shard` edge, and with it the whole generation: no package of
## the registry was indexed.
##
## Now, in one generation beside an ordinary package (`ok`, the control):
##
## * a version whose `.nimble` says more than a record holds (`manyreqs`,
##   `manybins`, `manyforeign`) or whose tree has more top-level modules
##   than a record lists (`manymodules`) is recorded `unreadable`, with its
##   digests, so it is not offered and is not lost;
## * a package listing more tags than an observation holds (`manytags`) is
##   not indexed and nothing of it is fetched; a package that already had
##   records (`grows`, which pushes 4100 tags at the second generation)
##   keeps them byte-identical, but is not frozen out of sight: its
##   observation says `refused` and the generation records a `gone` event,
##   once, so a package held at old versions is visible in the index.
##
## Falsifying mutations: the `read` edge encoding the record without its
## fallback fails the generation at `manyreqs`; `assemblePackage` without its
## bound check fails it at `manytags`; dropping the module-count check in
## `buildRecord` loses `manymodules`' version; keeping the previous
## observation, or no `gone` event, hides that `grows` is held.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./generator_fixtures

const
  Day = 86_400'u64
  T1 = 1_790_000_000'u64

proc tagsAt(work: string; n: int) =
  ## ``n`` version tags at ``work``'s `HEAD`, written in one ref update.
  let head = git(work, "rev-parse", "HEAD")
  var refs = ""
  for i in 1 .. n:
    refs.add "create refs/tags/v0." & $(i div 1000) & "." & $(i mod 1000) &
      " " & head & "\n"
  discard gitIn(work, refs, "update-ref", "--stdin")

suite "NPC-M11: one package past a bound of the index does not fail the generation":

  test "oversized metadata is unreadable, an oversized tag list is not indexed, the rest is published":
    let f = newFixture("m11-bounds")
    proc served(name: string; files: seq[FileSpec]): string =
      result = f.newRepo("nim/" & name & ".git")
      discard result.commit(files)
      result.tag("v1.0.0")
      result.publish()
    discard served("ok", @[nimbleFile("ok"), file("src/ok.nim", "discard\n")])
    var reqs: seq[string]
    for i in 1 .. 600: reqs.add "dep" & $i & " >= 1.0"
    discard served("manyreqs", @[nimbleFile("manyreqs", reqs),
      file("src/manyreqs.nim", "discard\n")])
    var bins = "bin = @["
    for i in 1 .. 300: bins.add (if i > 1: ", " else: "") & "\"b" & $i & "\""
    discard served("manybins", @[nimbleFile("manybins", extra = bins & "]\n"),
      file("src/manybins.nim", "discard\n")])
    var foreign = ""
    for i in 1 .. 70: foreign.add "foreignDep \"lib" & $i & "\"\n"
    discard served("manyforeign", @[nimbleFile("manyforeign", extra = foreign),
      file("src/manyforeign.nim", "discard\n")])
    var modules = @[nimbleFile("manymodules")]
    for i in 1 .. 1100: modules.add file("src/m" & $i & ".nim", "discard\n")
    discard served("manymodules", modules)
    let many = served("manytags", @[nimbleFile("manytags"),
      file("src/manytags.nim", "discard\n")])
    many.tagsAt(4100)
    many.publish()
    let grows = served("grows", @[nimbleFile("grows"),
      file("src/grows.nim", "discard\n")])
    let names = ["ok", "manyreqs", "manybins", "manyforeign", "manymodules",
      "manytags", "grows"]
    var entries: seq[(string, string)]
    for n in names: entries.add (n, f.url("nim/" & n & ".git"))
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(entries)])
    reg.publish()
    let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"), rc),
      "s.toml")
    let work = createTempDir("npc-m11-bounds-", "")

    let g1 = generate(f.genConfig(ss, T1, work / "state",
      outputDir = work / "g1"))
    checkpoint g1.diagnostics.join("\n")
    # The control, and the generation as a whole: published.
    check g1.built.hasPackage("ok")
    check g1.built.envelopeOf("ok").versions.len == 1
    check flUnreadable notin g1.built.envelopeOf("ok").versions[0].flags
    check fileExists(work / "g1" / "root")
    # Oversized metadata: the version is recorded, unreadable, with digests.
    for n in ["manyreqs", "manybins", "manyforeign", "manymodules"]:
      checkpoint n
      check g1.built.hasPackage(n)
      if g1.built.hasPackage(n):
        let v = g1.built.envelopeOf(n).versions
        check v.len == 1
        if v.len == 1:
          check flUnreadable in v[0].flags
          check v[0].size > 0
          check v[0].requires.len <= MaxRequirements
          check v[0].layout.modules.len <= MaxModules
    var modulesSaid = false
    for d in g1.diagnostics:
      if d.startsWith("manymodules@v1.0.0: ") and
          "top-level modules under srcDir, more than a record holds" in d:
        modulesSaid = true
    check modulesSaid
    # An oversized tag list: not indexed, nothing fetched, said why.
    check not g1.built.hasPackage("manytags")
    check g1.built.observationOf("manytags").state == osRefused
    for e in g1.executed:
      check not (e.family == efSource and e.subject.startsWith("manytags@"))
    var tagsSaid = false
    for d in g1.diagnostics:
      if d.startsWith("manytags: ") and "previous generation" in d:
        tagsSaid = true
    check tagsSaid
    let before = recordBytes(g1.built.envelopeOf("grows").versions[0])
    let beforeObs = g1.built.observationOf("grows")
    check beforeObs.tags.len == 1

    # `grows` pushes 4100 tags: its record and observation are kept.
    grows.tagsAt(4100)
    grows.publish()
    let g2 = generate(f.genConfig(ss, T1 + Day, work / "state",
      previous = work / "g1", outputDir = work / "g2"))
    checkpoint g2.diagnostics.join("\n")
    check g2.built.hasPackage("ok")
    let kept = g2.built.envelopeOf("grows").versions
    check kept.len == 1
    if kept.len == 1:
      check recordBytes(kept[0]) == before
    let heldObs = g2.built.observationOf("grows")
    check heldObs.state == osRefused
    check heldObs.tags.len == 0
    var growsEvents: seq[string]
    for e in g2.events:
      if e.package == "grows":
        growsEvents.add $e.kind & " " & e.before & " -> " & e.after
    check growsEvents == @["gone answering -> past a bound of the index format"]

    # Still past the bound: the records stay, and nothing is reported again.
    let g3 = generate(f.genConfig(ss, T1 + 2 * Day, work / "state",
      previous = work / "g2", outputDir = work / "g3"))
    checkpoint g3.diagnostics.join("\n")
    let still = g3.built.envelopeOf("grows").versions
    check still.len == 1
    if still.len == 1:
      check recordBytes(still[0]) == before
    check g3.built.observationOf("grows").state == osRefused
    for e in g3.events:
      check e.package != "grows"

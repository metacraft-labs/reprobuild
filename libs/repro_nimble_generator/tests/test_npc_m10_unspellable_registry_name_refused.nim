## NPC-M10 verification `test_npc_m10_unspellable_registry_name_refused`
## (P5; NPC-AREQ3).
##
## A registry with the entries `a.b`, `a/b` and `a:b` beside an ordinary
## one indexes the ordinary one only. `nimble:<name>` cannot spell a name
## holding `.`, `/` or `:`, so the generator refuses each such entry, keeps
## it among the skipped entries with that reason, and the report
## `repro catalog generate` prints names each refused entry and the reason.
## No origin of a refused entry is contacted.
##
## Falsifying mutation (recorded in the plan): accepting every printable
## name indexes `a.b` and fails the test.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./generator_fixtures

const Now = 1_790_000_000'u64

suite "NPC-M10: a registry name nimble:<name> cannot spell is refused":

  test "a.b, a/b and a:b are skipped with the reason; the ordinary entry is indexed":
    let f = newFixture("m10-unspellable")
    var urls: seq[(string, string)]
    for (name, path) in [("ordinary", "nim/ordinary.git"),
                         ("a.b", "nim/ab-dot.git"),
                         ("a/b", "nim/ab-slash.git"),
                         ("a:b", "nim/ab-colon.git")]:
      let repo = f.newRepo(path)
      discard repo.commit(@[nimbleFile("x"), file("src/x.nim", "discard\n")])
      repo.tag("v1.0.0")
      repo.publish()
      urls.add (name, f.url(path))
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(urls)])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let work = createTempDir("npc-m10-unspellable-", "")
    var cfg = f.genConfig(parseSourceSet(sourceSetText(regUrl, regCommit),
      "s.toml"), Now, work / "state", outputDir = work / "index")
    var contacted: seq[string]
    cfg.observer = proc(family: EdgeFamily; url: string) {.gcsafe.} =
      {.cast(gcsafe).}: contacted.add url
    let g = generate(cfg)

    check g.built.hasPackage("ordinary")
    check g.built.root.packageCount == 1
    for name in ["a.b", "a/b", "a:b"]:
      check not g.built.hasPackage(name)
    check g.skipped.len == 3
    let report = skippedReport(g)
    checkpoint report.join("\n")
    check report.len == 3
    for (name, ch) in [("a.b", "."), ("a/b", "/"), ("a:b", ":")]:
      var found = 0
      for s in g.skipped:
        if s.entry == name:
          inc found
          check s.registry == regUrl
          check ch.escape() in s.reason
          check "nimble:<name>" in s.reason
      check found == 1
      var lines = 0
      for l in report:
        if name.escape() in l and "cannot spell" in l: inc lines
      check lines == 1
    for u in contacted:
      check "ab-" notin u

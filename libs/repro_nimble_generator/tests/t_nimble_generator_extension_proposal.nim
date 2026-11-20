## NPC-AREQ10: a name the pinned index lacks is generated as a PROPOSAL --
## the closure of that package, as a candidate change (source set and
## published index) beside the index repository, which nothing uses until it
## is committed. Roots restrict an index to their closure.

import std/[options, os, strutils, tempfiles, unittest]

import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

suite "the on-demand extension proposal":

  test "a missing name is proposed with its closure; the index itself is unchanged":
    let f = newFixture("proposal")
    var entries: seq[(string, string)]
    for (name, reqs) in [("app", @["lib"]), ("lib", @[]),
                         ("tool", @["helper"]), ("helper", @[]),
                         ("unrelated", @[])]:
      let w = f.newRepo("nim/" & name & ".git")
      discard w.commit(@[nimbleFile(name, reqs), file("src/" & name & ".nim",
        "discard\n")])
      w.tag("v1.0.0")
      w.publish()
      entries.add (name, f.url("nim/" & name & ".git"))
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(entries)])
    reg.publish()
    let text = sourceSetText(f.url("nim-lang/packages.git"), regCommit,
      "\n[[root]]\npackage = \"app\"\n")
    let work = createTempDir("npc-m4-proposal-run-", "")
    let repo = work / "index-repo"
    let g = generate(f.genConfig(parseSourceSet(text, "s.toml"), 1_790_000_000,
      work / "state", outputDir = repo / "published-index"))
    check g.built.hasPackage("app")
    check g.built.hasPackage("lib")         # in app's closure
    check not g.built.hasPackage("tool")    # outside it
    check not g.built.hasPackage("unrelated")
    let before = readFile(repo / "published-index" / "root")

    let p = proposeExtension(f.genConfig(parseSourceSet(text, "s.toml"),
      1_790_086_400, work / "state", previous = repo / "published-index"),
      text, @["tool"], work / "proposal")
    check p.result.built.hasPackage("tool")
    check p.result.built.hasPackage("helper")
    check p.result.built.hasPackage("app")
    check not p.result.built.hasPackage("unrelated")
    check p.result.built.root.previousRoot.isSome
    check fileExists(work / "proposal" / "published-index" / "root")
    check "package = \"tool\"" in readFile(work / "proposal" / "nimble-sources.toml")
    # The index repository is untouched.
    check readFile(repo / "published-index" / "root") == before

    # A whole-registry index has no roots to extend.
    let whole = sourceSetText(f.url("nim-lang/packages.git"), regCommit)
    expect GeneratorError:
      discard proposeExtension(f.genConfig(parseSourceSet(whole, "s.toml"),
        1_790_086_400, work / "state2"), whole, @["tool"], work / "proposal2")

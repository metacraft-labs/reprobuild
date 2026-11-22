## NPC-M13 verification `test_npc_m13_submodule_nesting_bounded`
## (threat model G38, T35).
##
## A self-referential repository: `nim/chain.git`, each of whose commits
## `K1..K9` includes the repository itself (`url = ../chain.git`) at the
## commit before it, down to `K0`, which has none. A package whose gitlink
## pins `K8` nests 9 levels deep and is not offered, with a `gone` event
## "nesting bound exceeded"; one pinning `K7` nests 8 levels and is offered
## (positive control).
##
## A cycle (a submodule whose URL identity and commit are an ancestor's)
## cannot be built from real commits: a commit would have to contain its own
## id. The walk is therefore given, as a worker output may claim, a
## submodule tree whose gitlink names itself, and refuses it as a cycle; it
## also refuses a version naming more than 256 submodules.
##
## Falsifying mutation: removing the depth bound makes the deep fixture
## fetch past 8 levels and be offered.

import std/[options, os, strutils, tables, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./submodule_fixtures

suite "NPC-M13: submodule nesting is bounded":
  test "9 levels: not offered; 8 levels: offered (self-including repository)":
    let f = newFixture("m13-nesting")
    let work = createTempDir("npc-m13-nesting-", "")
    let chain = f.newRepo("nim/chain.git")
    var k = @[chain.commit(@[file("leaf.txt", "leaf\n")])]
    for i in 1 .. 9:
      k.add chain.commit(@[file("level.txt", $i & "\n"),
        gitmodules(@[("self", "../chain.git")]), gitlinkTo("self", k[^1])])
    chain.publish()
    for (name, pin) in [("deep8", k[7]), ("deep9", k[8])]:
      discard f.served("nim/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "discard\n"),
        gitmodules(@[("vendor/chain", f.url("nim/chain.git"))]),
        gitlinkTo("vendor/chain", pin)], tags = @["v1.0.0"])
    let reg = f.registryOf(@[("deep8", f.url("nim/deep8.git")),
      ("deep9", f.url("nim/deep9.git"))])
    let g = f.generation(reg, 1_790_000_000, work / "state")
    checkpoint "events: " & $g.events
    checkpoint "diagnostics: " & g.diagnostics.join("\n")

    # 8 levels: offered, every level in the record.
    let r8 = g.built.recordOf("deep8", "v1.0.0")
    require r8.isSome
    check r8.get.submodules.len == 8
    check r8.get.submodules[^1].path ==
      "vendor/chain" & repeat("/self", 7)
    check r8.get.submodules[^1].commit == k[0]
    check g.built.offeredTags("deep8") == @["v1.0.0"]
    # 9 levels: not offered, one event naming the deepest submodule.
    check not g.built.hasPackage("deep9")
    let gone = g.goneOf("deep9")
    check gone.len == 1
    if gone.len == 1:
      check gone[0].after == "submodule vendor/chain" & repeat("/self", 8) &
        ": nesting bound exceeded"
    # The ninth level was never fetched: K0 is fetched once, for deep8.
    var fetchedK0 = 0
    for s in g.executedOf(efSubmodule):
      if s.endsWith("@" & k[0]): inc fetchedK0
    check fetchedK0 == 1

  test "a claimed cycle and more than 256 submodules are refused by the walk":
    let base = "https://forge.test/nim/top.git"
    let selfUrl = "https://forge.test/nim/loop.git"
    let loopCommit = repeat('a', 40)
    let root = FetchedTree(entries: @[
      TreeEntry(kind: teFile, mode: "100644", oid: repeat('1', 40),
        path: "top.nimble"),
      TreeEntry(kind: teGitlink, mode: "160000", oid: loopCommit,
        path: "vendor/loop")],
      blobs: {repeat('1', 40): "x"}.toTable, hasGitmodules: true,
      gitmodules: "[submodule \"l\"]\n\tpath = vendor/loop\n\turl = " &
        selfUrl & "\n")
    # The loop's tree names itself at its own commit.
    let looped = FetchedTree(entries: @[TreeEntry(kind: teGitlink,
      mode: "160000", oid: loopCommit, path: "again")], hasGitmodules: true,
      gitmodules: "[submodule \"a\"]\n\tpath = again\n\turl = ./\n")
    let loopLookup = proc(url, identity, commit: string): SubmoduleLookup =
      SubmoduleLookup(state: slReady, tree: looped)
    let c = composeSource(root, "", base, repeat('b', 40), loopLookup)
    check c.state == coFailed
    check c.failure.failure == sfCycle
    check c.failure.path == "vendor/loop/again"
    check eventPhrase(c.failure) == "submodule vendor/loop/again: cycle"

    # 257 submodules in one tree.
    var many = FetchedTree(hasGitmodules: true)
    for i in 0 .. MaxSubmodules:
      let p = "m/" & $i
      many.entries.add TreeEntry(kind: teGitlink, mode: "160000",
        oid: toHex(i, 40).toLowerAscii(), path: p)
      many.gitmodules.add "[submodule \"" & p & "\"]\n\tpath = " & p &
        "\n\turl = https://forge.test/nim/m" & $i & ".git\n"
    let empty = proc(url, identity, commit: string): SubmoduleLookup =
      SubmoduleLookup(state: slReady, tree: FetchedTree())
    let c2 = composeSource(many, "", base, repeat('b', 40), empty)
    check c2.state == coFailed
    check c2.failure.failure == sfCount
    # Exactly the bound is accepted (positive control).
    many.entries.setLen(MaxSubmodules)
    let c3 = composeSource(many, "", base, repeat('b', 40), empty)
    check c3.state == coComposed
    check c3.pins.len == MaxSubmodules

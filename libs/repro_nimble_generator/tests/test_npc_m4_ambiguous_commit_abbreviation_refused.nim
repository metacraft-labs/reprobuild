## NPC-M4 verification `test_npc_m4_ambiguous_commit_abbreviation_refused`
## (threat model G15, NPC-AREQ17): a `#<commit>` requirement whose
## abbreviation matches two commits of the origin is refused at generation,
## naming both; an unambiguous one is expanded to the full id.
##
## The colliding pair is real: two commit objects of the target origin
## whose ids share their first seven hex digits, found by hashing commit
## objects that differ only in their message (a birthday search, about
## 2^14 hashes) and then written into the repository, where git computes
## the same ids. An attacker can do the same; the reader accepts
## abbreviations of seven digits and more.

import std/[options, os, strutils, tables, tempfiles, unittest]

import nimcrypto/[hash, sha]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

proc commitBody(tree: string; n: int): string =
  "tree " & tree & "\nauthor A <a@example.invalid> 1700000000 +0000\n" &
    "committer A <a@example.invalid> 1700000000 +0000\n\ncandidate " & $n & "\n"

proc commitId(body: string): string =
  ($sha1.digest("commit " & $body.len & "\0" & body)).toLowerAscii()

proc collidingPair(tree: string): (int, int, string) =
  var seen = initTable[string, int]()
  var n = 0
  while true:
    let id = commitId(commitBody(tree, n))
    let p = id[0 ..< 7]
    if p in seen: return (seen[p], n, p)
    seen[p] = n
    inc n

suite "NPC-M4: an ambiguous #<commit> abbreviation is refused":

  test "two commits share the abbreviation: refused, naming both; a unique one expands":
    let f = newFixture("abbrev")
    let target = f.newRepo("nim/target.git")
    discard target.commit(@[nimbleFile("target"), file("src/target.nim",
      "discard\n")])
    target.tag("v1.0.0")
    let tree = git(target, "rev-parse", "HEAD^{tree}")
    let (a, b, prefix) = collidingPair(tree)
    let idA = gitIn(target, commitBody(tree, a), "hash-object", "-t",
      "commit", "-w", "--stdin")
    let idB = gitIn(target, commitBody(tree, b), "hash-object", "-t",
      "commit", "-w", "--stdin")
    check idA == commitId(commitBody(tree, a))
    check idA.startsWith(prefix)
    check idB.startsWith(prefix)
    check idA != idB
    discard git(target, "branch", "collide-a", idA)
    discard git(target, "branch", "collide-b", idB)
    let unique = target.commit(@[nimbleFile("target", @["nim >= 1.0"]),
      file("src/target.nim", "echo 2\n")], date = 1_700_100_000)
    target.publish()

    let user = f.newRepo("nim/user.git")
    let ambiguousCommit = user.commit(@[nimbleFile("user",
      @["target#" & prefix]), file("src/user.nim", "discard\n")])
    user.tag("v1.0.0")
    let uniqueCommit = user.commit(@[nimbleFile("user",
      @["target#" & unique[0 ..< 9]]), file("src/user.nim", "discard\n")],
      date = 1_700_200_000)
    user.tag("v2.0.0")
    user.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("target", f.url("nim/target.git")), ("user", f.url("nim/user.git"))])])
    reg.publish()
    let work = createTempDir("npc-m4-abbrev-run-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit), "s.toml"), 1_790_000_000,
      work / "state"))

    let u = g.built.envelopeOf("user")
    var refusedNamesBoth = false
    for d in g.diagnostics:
      if "abbreviation " & prefix in d and idA in d and idB in d:
        refusedNamesBoth = true
    check refusedNamesBoth
    for v in u.versions:
      if v.commit == ambiguousCommit:
        check flUnreadable in v.flags
        check v.requires.len == 1
        check v.requires[0].constraint == prefix  # kept as written
      elif v.commit == uniqueCommit:
        check flUnreadable notin v.flags
        check v.requires.len == 1
        check v.requires[0].versionKind == rvCommit
        check v.requires[0].constraint == unique  # expanded to the full id
    # The commit the unambiguous requirement names is a version of target.
    var pseudo = 0
    for v in g.built.envelopeOf("target").versions:
      if v.version.kind == rvkCommit and v.commit == unique: inc pseudo
    check pseudo == 1

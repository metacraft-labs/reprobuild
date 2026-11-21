## NPC-M6: NPC-M3's solver input connected to the solver (the plan's items
## a-e), solved by the real clingo driver over an index the production
## writer built:
##
## (a) each version's own requirements decide (``versionDepends``);
## (b) a record's `nim` range constrains the project's `nim` toolchain and is
##     never a `nimble:nim` package;
## (c) `#head` and `#<commit>` (and a URL requirement) select exactly the
##     record they name; every other requirer excludes it;
## (d) two tags that read as one solver version: at one commit one is
##     offered, at two commits neither is (and `#<commit>` still reaches
##     each);
## (e) a name the index does not hold is reported as missing, with the
##     requirement chain, instead of failing the solve's encoding;
##
## plus `--exclude-newer` (NPC-AREQ18) and the requirement chain of a
## failure. No mock: the index is in memory because where its bytes come
## from is not what is tested here.

import std/[strutils, tables, unittest]

import repro_nimble_index
import repro_solver/version_encoder

import ./resolution_fixtures

suite "NPC-M6: Nimble requirements resolve through the solver":
  test "(a) each version's own requirements decide which versions fit":
    # a 1.0.0 needs b < 2, a 2.0.0 needs b >= 2; the project wants b < 2.
    let r = resolve(@[
      package("a", @[tagged("a", "1.0.0", @[req("b", "< 2.0.0")]),
                     tagged("a", "2.0.0", @[req("b", ">= 2.0.0")])]),
      package("b", @[tagged("b", "1.0.0"), tagged("b", "2.0.0")])],
      @[("a", ""), ("b", "< 2.0.0")])
    check r.failure == ""
    check r.chosen["nimble:a"] == "1.0.0"
    check r.chosen["nimble:b"] == "1.0.0"
    # Without a constraint the newest of each is chosen (preferNewest).
    let free = resolve(@[
      package("a", @[tagged("a", "1.0.0", @[req("b", "< 2.0.0")]),
                     tagged("a", "2.0.0", @[req("b", ">= 2.0.0")])]),
      package("b", @[tagged("b", "1.0.0"), tagged("b", "2.0.0")])],
      @[("a", "")])
    check free.chosen["nimble:a"] == "2.0.0"
    check free.chosen["nimble:b"] == "2.0.0"

  test "(a) a package only an unchosen version requires is not in the answer":
    let r = resolve(@[
      package("a", @[tagged("a", "1.0.0", @[req("legacy")]),
                     tagged("a", "2.0.0")]),
      package("legacy", @[tagged("legacy", "1.0.0")])],
      @[("a", ">= 2.0.0")])
    check r.failure == ""
    check r.chosen["nimble:a"] == "2.0.0"
    check "nimble:legacy" notin r.chosen

  test "(b) `nim` ranges constrain the toolchain, never a nimble:nim package":
    let pkgs = @[package("a", @[
      tagged("a", "1.0.0", nim = ">= 1.6.0, < 2.0.0"),
      tagged("a", "2.0.0", nim = ">= 2.2.0")])]
    let r = resolve(pkgs, @[("a", "")], nimVersions = @["1.6.14", "2.0.8"])
    check r.failure == ""
    # 2.0.0 needs nim >= 2.2, which no candidate offers: a falls back.
    check r.chosen["nimble:a"] == "1.0.0"
    check r.chosen["nim"] == "1.6.14"
    check "nimble:nim" notin r.chosen
    for d in lowerToSolver(r.input, toolchainNim = "nim"):
      check d.name != "nimble:nim"
    # With a newer toolchain available, the newer record is chosen.
    let newer = resolve(pkgs, @[("a", "")], nimVersions = @["1.6.14", "2.2.4"])
    check newer.chosen["nimble:a"] == "2.0.0"
    check newer.chosen["nim"] == "2.2.4"

  test "(c) #head selects the head record, which no range admits":
    let head = pseudo("x", rvkHead, "main", commitOf("x@main"))
    let pkgs = @[
      package("x", @[tagged("x", "1.0.0"), head]),
      package("wantshead", @[tagged("wantshead", "1.0.0", @[headReq("x")])])]
    let ranged = resolve(pkgs, @[("x", ">= 0.0.0")])
    check ranged.chosen["nimble:x"] == "1.0.0"
    let named = resolve(pkgs, @[("wantshead", "")])
    check named.failure == ""
    check named.chosen["nimble:x"] == "#head"
    # One version per name: a requirer naming #head and one naming a range
    # cannot both be satisfied.
    let both = resolve(pkgs, @[("wantshead", ""), ("x", ">= 1.0.0")])
    check both.failure.len > 0

  test "(c) #<commit>, abbreviated, selects the record of that commit":
    let c = commitOf("y@pinned")
    let pkgs = @[
      package("y", @[tagged("y", "1.0.0"),
        pseudo("y", rvkCommit, "", c)]),
      package("p", @[tagged("p", "1.0.0", @[commitReq("y", c[0 ..< 8])])])]
    let r = resolve(pkgs, @[("p", "")])
    check r.failure == ""
    check r.chosen["nimble:y"] == "#commit/" & c
    # A commit the index does not hold is unresolvable, and said so.
    let missing = resolve(@[pkgs[0], package("q", @[tagged("q", "1.0.0",
      @[commitReq("y", "deadbeef")])])], @[("q", "")])
    check missing.failure.len > 0
    check "the index records no commit deadbeef of y" in missing.failure

  test "(c) a URL requirement resolves to the unlisted source indexed for it":
    let url = "https://Example.invalid/Someone/Thing.git"
    var thing = tagged("example.invalid/someone/thing", "0.3.0")
    thing.flags.incl flUnlisted
    let pkgs = @[
      package("example.invalid/someone/thing", @[thing]),
      package("z", @[tagged("z", "1.0.0", @[urlReq(url, ">= 0.3.0")])])]
    let r = resolve(pkgs, @[("z", "")])
    check r.failure == ""
    check r.chosen["nimble:example.invalid/someone/thing"] == "0.3.0"
    check r.input.urlTargets == @[url]

  test "(d) two tags of one version: one commit offers one, two commits none":
    var sameA = tagged("s", "v1.0")
    var sameB = tagged("s", "1.0.0")
    sameB.commit = sameA.commit
    sameB.tree = sameA.tree
    let same = resolve(@[package("s", @[sameA, sameB])], @[("s", "")])
    check same.failure == ""
    check same.chosen["nimble:s"] == "1.0.0"
    let pkgS = same.input.packages[same.input.packageOf("s")]
    var offered, duplicate = 0
    for c in pkgS.candidates:
      if c.offered: inc offered
      for e in c.exclusions:
        if e.kind == exDuplicateTag: inc duplicate
    check offered == 1
    check duplicate == 1
    # Different commits: neither is offered under 1.0.0 ...
    let diff = resolve(@[package("d", @[tagged("d", "v1.0"),
      tagged("d", "1.0.0"), tagged("d", "0.9.0")])], @[("d", "")])
    check diff.failure == ""
    check diff.chosen["nimble:d"] == "0.9.0"
    let pkgD = diff.input.packages[diff.input.packageOf("d")]
    var equal = 0
    for c in pkgD.candidates:
      for e in c.exclusions:
        if e.kind == exEqualVersion:
          inc equal
          check "v1.0" in e.detail
          check "1.0.0" in e.detail
    check equal == 2
    # ... and `#<commit>` still reaches either one.
    let v10 = commitOf("d@v1.0")
    let byCommit = resolve(@[package("d", @[tagged("d", "v1.0"),
      tagged("d", "1.0.0")]), package("w", @[tagged("w", "1.0.0",
      @[commitReq("d", v10)])])], @[("w", "")])
    check byCommit.failure == ""
    check byCommit.chosen["nimble:d"] == "#commit/" & v10

  test "(e) a name the index does not hold is missing, with its chain":
    let pkgs = @[
      package("top", @[tagged("top", "1.0.0", @[req("mid")])]),
      package("mid", @[tagged("mid", "2.0.0", @[req("ghost", ">= 1.0.0")])])]
    let r = resolve(pkgs, @[("top", "")])
    check r.input.missing == @["ghost"]
    check r.failure.len > 0
    check "nimble:ghost is not in the index" in r.failure
    check "app requires nimble:top" in r.failure
    check "nimble:top 1.0.0 requires mid" in r.failure
    check "nimble:mid 2.0.0 requires ghost >= 1.0.0" in r.failure
    # The lowering declares it without a candidate (not dropped).
    var declared = false
    for d in lowerToSolver(r.input):
      if d.name == "nimble:ghost":
        declared = true
        check d.versions.len == 0
        check d.onDemand
    check declared
    # A version that does not need it is still chosen.
    let alt = resolve(@[
      package("top", @[tagged("top", "1.0.0", @[req("ghost")]),
                       tagged("top", "0.9.0")])], @[("top", "")])
    check alt.failure == ""
    check alt.chosen["nimble:top"] == "0.9.0"

  test "--exclude-newer excludes records first seen after the bound":
    let pkgs = @[package("n", @[
      tagged("n", "1.0.0", firstSeen = 1_700_000_000),
      tagged("n", "1.1.0", firstSeen = 1_800_000_000)])]
    check resolve(pkgs, @[("n", "")]).chosen["nimble:n"] == "1.1.0"
    let bounded = resolve(pkgs, @[("n", "")],
      options = NimbleSolveOptions(excludeNewer: 1_750_000_000))
    check bounded.chosen["nimble:n"] == "1.0.0"
    let none = resolve(pkgs, @[("n", ">= 1.1.0")],
      options = NimbleSolveOptions(excludeNewer: 1_750_000_000))
    check none.failure.len > 0
    check "newer: first seen 2027-01-15T08:00:00Z" in none.failure

  test "--lowest picks the lowest admissible versions of the closure":
    let pkgs = @[package("l", @[tagged("l", "1.0.0"), tagged("l", "1.2.0"),
      tagged("l", "2.0.0")])]
    check resolve(pkgs, @[("l", ">= 1.1.0")],
      preference = vpLowest).chosen["nimble:l"] == "1.2.0"
    check resolve(pkgs, @[("l", ">= 1.1.0")]).chosen["nimble:l"] == "2.0.0"

  test "a repointed name's new origin is a separate, excluded candidate":
    var old = tagged("r", "1.0.0")
    var fork = tagged("r", "2.0.0")
    fork.origin = 1
    var env = package("r", @[old, fork])
    env.origins.add PackageOrigin(url: "https://example.invalid/fork/r",
      vcs: ovGit)
    env.registryOrigin = 1
    let r = resolve(@[env], @[("r", "")])
    check r.chosen["nimble:r"] == "1.0.0"
    # Accepting the new origin (what the project's own edit does) offers it.
    var accepted = NimbleSolveOptions(excludeNewer: -1)
    accepted.acceptedOrigins["r"] = "https://example.invalid/fork/r"
    check resolve(@[env], @[("r", "")],
      options = accepted).chosen["nimble:r"] == "2.0.0"

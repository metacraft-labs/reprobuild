## NPC-M11 adversarial audit (threat model G31): attacks on the generator
## that an existing control stops, kept as regressions. Each case names the
## control; the audit report maps them to the threat model's rows.
##
## * Annotated-tag / commit confusion (T7): a version is the commit a tag
##   peels to, never the tag object; a tag at a tree or a blob is not a
##   version (`fetchCommit` checks the object type); a tag of a tag peels
##   through both; `#<id of a tag object>` is not a commit and no version
##   of it exists; its abbreviation expands to no commit.
## * `?subdir=` that escapes (spec § 3, NPC-AREQ4): `../..`, `/etc`,
##   `pkg/../..` and `.git` select tree entries by prefix
##   (`origin_git.readTree`), so they select nothing outside the
##   repository: the version has no `.nimble` and is unreadable, and its
##   archive holds no file. `?subdir=pkg` is the positive control.
## * Style-insensitive name collisions (T10, NPC-AREQ3): a registry entry
##   whose name folds onto an earlier one is skipped with the reason; an
##   `[[extra]]` that folds onto a registry name is refused; a colliding
##   entry inserted ahead of an indexed package is a `repointed` event, and
##   the solve keeps the recorded origin (`repointed-origin`, G7).
## * Origin hosts spelled as numbers (T3): `0177.0.0.1`, `2130706433`,
##   `0x7f000001` and `127.1` are loopback to the system resolver, which
##   the policy asks before classifying, so each is refused as an address
##   (`egress.vetHost`); none is contacted.
## * An endless ref list and a decompression bomb (T4): 100000 refs, and a
##   64 MiB blob of zeros that packs to under 1 MiB, each pass the byte
##   limit of the run (`origin_git.runBounded` counts what git writes, not
##   what it transfers) and are refused as `size`; the other package of the
##   generation is indexed.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_generator/[origin_git, source_tree]
import repro_nimble_index

import ./generator_fixtures
import ./snapshot_fixtures

const T1 = 1_790_000_000'u64

proc diagnosed(g: GenerationResult; prefix, text: string): bool =
  for d in g.diagnostics:
    if d.startsWith(prefix) and text in d: return true

suite "NPC-M11: hostile origin and registry inputs the generator stops":

  test "annotated tags, tags at trees and blobs, and #<tag object> are not commits":
    let f = newFixture("m11-tags")
    let r = f.newRepo("nim/tagged.git")
    let c1 = r.commit(@[nimbleFile("tagged"), file("src/tagged.nim", "discard\n")])
    r.annotatedTag("v1.0.0")
    let tagObject = git(r, "rev-parse", "v1.0.0")
    discard git(r, "tag", "-a", "-m", "a tree", "v2.0.0",
      git(r, "rev-parse", "HEAD^{tree}"))
    discard git(r, "tag", "v3.0.0", git(r, "rev-parse", "HEAD:tagged.nimble"))
    discard git(r, "tag", "-a", "-m", "a tag", "v4.0.0", "v1.0.0")
    r.publish()
    check tagObject != c1
    let user = f.newRepo("nim/user.git")
    discard user.commit(@[nimbleFile("user", @["tagged#" & tagObject]),
      file("src/user.nim", "discard\n")])
    user.tag("v1.0.0")
    discard user.commit(@[nimbleFile("user", @["tagged#" & tagObject[0 ..< 10]]),
      file("src/user.nim", "discard\n")])
    user.tag("v1.1.0")
    user.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("tagged", f.url("nim/tagged.git")),
      ("user", f.url("nim/user.git"))])])
    reg.publish()
    let work = createTempDir("npc-m11-tags-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), rc), "s.toml"), T1, work / "state"))
    checkpoint g.diagnostics.join("\n")
    var byTag = initTable[string, string]()
    for v in g.built.envelopeOf("tagged").versions:
      byTag[v.version.tag] = v.commit
    check byTag.getOrDefault("v1.0.0") == c1
    check byTag.getOrDefault("v4.0.0") == c1
    check "v2.0.0" notin byTag
    check "v3.0.0" notin byTag
    for v in g.built.envelopeOf("tagged").versions:
      check v.commit != tagObject
    check g.diagnosed("tagged@v2.0.0: ", "is a tree")
    check g.diagnosed("tagged@v3.0.0: ", "is a blob")
    check g.diagnosed("tagged@" & tagObject & ": ", "is a tag")
    check g.diagnosed("user@v1.1.0: ", "no commit of tagged starts with " &
      tagObject[0 ..< 10])
    # `user` 1.0.0 names the tag object: no record of it exists, so no
    # solve can take it.
    let s = solveOver(g.built.objectTable(), g.built.rootId, @["user == 1.0.0"])
    check s.failure.len > 0
    check "nimble:tagged" notin s.chosen

  test "a ?subdir= that escapes selects nothing outside the repository":
    let f = newFixture("m11-subdir")
    let r = f.newRepo("nim/mono.git")
    discard r.commit(@[nimbleFile("mono"), file("src/mono.nim", "discard\n"),
      file("pkg/inner.nimble", "version = \"1.0.0\"\nsrcDir = \"src\"\n"),
      file("pkg/src/inner.nim", "discard\n")])
    r.tag("v1.0.0")
    r.publish()
    let escapes = @[("up", "../.."), ("abs", "/etc"), ("mid", "pkg/../.."),
      ("dotgit", ".git")]
    var entries = @[("inner", f.url("nim/mono.git") & "?subdir=pkg")]
    for (n, s) in escapes: entries.add (n, f.url("nim/mono.git") & "?subdir=" & s)
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(entries)])
    reg.publish()
    let work = createTempDir("npc-m11-subdir-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), rc), "s.toml"), T1, work / "state"))
    checkpoint g.diagnostics.join("\n")
    let inner = g.built.envelopeOf("inner").versions
    check inner.len == 1
    check flUnreadable notin inner[0].flags
    check inner[0].layout.modules == @["inner"]
    # The empty tree's digest: what every escaping subdir selected.
    let emptyFacts = sourceFacts(FetchedTree()).facts
    for (n, _) in escapes:
      checkpoint n
      let v = g.built.envelopeOf(n).versions
      check v.len == 1
      check flUnreadable in v[0].flags
      check v[0].layout.modules.len == 0
      check $v[0].tree == emptyFacts.treeDigest
      check g.diagnosed(n & "@v1.0.0: ", "the tree has no `.nimble` file")

  test "style-insensitive collisions are skipped, refused, or a repoint the solve does not follow":
    let f = newFixture("m11-collide")
    for n in ["foobar", "evil"]:
      let r = f.newRepo("nim/" & n & ".git")
      discard r.commit(@[nimbleFile("foobar"),
        file("src/foobar.nim", "proc who*(): string = \"" & n & "\"\n")])
      r.tag("v1.0.0")
      if n == "evil": r.tag("v1.1.0")
      r.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let r1 = reg.commit(@[packagesJson(@[("foobar", f.url("nim/foobar.git")),
      ("FOO_BAR", f.url("nim/evil.git"))], @[("Foo_bar_", "evil")])])
    let r2 = reg.commit(@[packagesJson(@[("Foo_Bar", f.url("nim/evil.git")),
      ("foobar", f.url("nim/foobar.git"))])])
    reg.publish()
    let regUrl = f.url("nim-lang/packages.git")
    let work = createTempDir("npc-m11-collide-", "")
    let g1 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl, r1),
      "s.toml"), T1, work / "state", outputDir = work / "g1"))
    var skipped: seq[string]
    for s in g1.skipped: skipped.add s.entry & ": " & s.reason
    checkpoint skipped.join("\n")
    check "FOO_BAR: its name collides with foobar under the style-insensitive comparison" in skipped
    check "Foo_bar_: its name collides with foobar under the style-insensitive comparison" in skipped
    check g1.built.envelopeOf("foobar").origins.len == 1
    check g1.built.envelopeOf("foobar").origins[0].url == f.url("nim/foobar.git")
    # An `[[extra]]` spelled to fold onto a registry name.
    var refused = ""
    try:
      discard generate(f.genConfig(parseSourceSet(sourceSetText(regUrl, r1,
        "\n[[extra]]\nname = \"fooBAR\"\norigin = " &
        f.url("nim/evil.git").escape() & "\n"), "s.toml"), T1,
        work / "state-extra"))
    except GeneratorError as e:
      refused = e.msg
    check "[[extra]] fooBAR is also a registry package" in refused
    # A colliding entry inserted ahead of the indexed package.
    let g2 = generate(f.genConfig(parseSourceSet(sourceSetText(regUrl, r2),
      "s.toml"), T1 + 86_400, work / "state", previous = work / "g1",
      outputDir = work / "g2"))
    var events: seq[string]
    for e in g2.events: events.add $e.kind & " " & e.before & " -> " & e.after
    check ("repointed " & f.url("nim/foobar.git") & " -> " &
      f.url("nim/evil.git")) in events
    let s = solveOver(g2.built.objectTable(), g2.built.rootId, @["foobar"])
    checkpoint s.failure
    check s.failure == ""
    let pi = s.input.packageOf("foobar")
    var offered: seq[string]
    for c in s.input.packages[pi].candidates:
      if c.offered:
        offered.add c.version
        check s.input.packages[pi].origins[c.record.origin].url ==
          f.url("nim/foobar.git")
      else:
        check c.exclusions[0].kind == exOtherOrigin
    check offered == @["1.0.0"]

  test "origin hosts spelled as numbers resolve to loopback and are refused":
    let policy = defaultPolicy()
    for host in ["0177.0.0.1", "2130706433", "0x7f000001", "127.1",
                 "0177.1", "0x7f.1"]:
      checkpoint host
      var refusal: EgressRefusal
      try:
        discard vetOrigin(policy, "https://" & host & "/nim/x.git")
      except EgressError as e:
        refusal = e.refusal
      check refusal.kind == erAddress
      check refusal.addressClass == acLoopback
      check refusal.address == "127.0.0.1"

  test "an endless ref list and a decompression bomb pass the byte limit and are refused":
    let f = newFixture("m11-t4")
    let ok = f.newRepo("nim/ok.git")
    discard ok.commit(@[nimbleFile("ok"), file("src/ok.nim", "discard\n")])
    ok.tag("v1.0.0")
    ok.publish()
    let huge = f.newRepo("nim/huge.git")
    let head = huge.commit(@[nimbleFile("huge"), file("src/huge.nim", "discard\n")])
    huge.tag("v1.0.0")
    huge.publish()
    var packed = "# pack-refs with: peeled fully-peeled sorted \n"
    for i in 0 ..< 100_000:
      packed.add head & " refs/tags/x" & align($i, 8, '0') & "\n"
    writeFile(f.root / "nim/huge.git" / "packed-refs", packed)
    let bomb = f.newRepo("nim/bomb.git")
    discard bomb.commit(@[nimbleFile("bomb"), file("src/bomb.nim", "discard\n"),
      file("zeros.bin", repeat('\0', 64 * 1024 * 1024))])
    bomb.tag("v1.0.0")
    bomb.publish()
    var served = 0'i64
    for p in walkDirRec(f.root / "nim/bomb.git"): served += getFileSize(p)
    check served < 1024 * 1024
    let reg = f.newRepo("nim-lang/packages.git")
    let rc = reg.commit(@[packagesJson(@[("ok", f.url("nim/ok.git")),
      ("huge", f.url("nim/huge.git")), ("bomb", f.url("nim/bomb.git"))])])
    reg.publish()
    var limits = DefaultLimits
    limits.maxBytes = 4 * 1024 * 1024
    let work = createTempDir("npc-m11-t4-", "")
    let g = generate(f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), rc), "s.toml"), T1, work / "state",
      limits = limits))
    var refusals = initTable[string, EgressRefusal]()
    for r in g.refusals:
      if r.package notin refusals: refusals[r.package] = r.refusal
    checkpoint $refusals
    check refusals["huge"].kind == erSize
    check g.built.observationOf("huge").state == osRefused
    check refusals["bomb"].kind == erSize
    check not g.built.hasPackage("bomb")
    check "ok" notin refusals
    check g.built.envelopeOf("ok").versions.len == 1

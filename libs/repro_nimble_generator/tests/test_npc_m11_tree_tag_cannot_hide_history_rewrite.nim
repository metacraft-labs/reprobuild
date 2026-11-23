## NPC-M11 adversarial audit (threat model T7, G31; NPC-AREQ4): a tag that
## names a tree cannot keep a rewritten history from being reported.
##
## The generator learns that history was rewritten from a commits-only
## fetch of the origin's branches and tags (`--filter=tree:0`). A tag may
## name a tree object; `tree:0` filters that tree out like every other, and
## git then refuses the whole fetch as incomplete ("did not send all
## necessary objects"). Before this audit the generator took that failure
## as "history unknown" and recorded no `history-rewritten` event, so an
## origin that force-pushed over a recorded version and also pushed a tag
## at a tree hid the rewrite. The same failure made every `#<commit>`
## abbreviation of the package unexpandable.
##
## Now the fetch is repeated with `tree:1` (the tips' root trees too) when
## the commits-only one fails, and the event is recorded as for an origin
## with no such tag. An annotated tag at a tree is tried as well as a
## lightweight one.
##
## The retry is not a second budget: it gets what the first attempt left of
## the byte limit, so an origin that makes the commits-only fetch fail on
## purpose cannot have the generator take its commits twice.
##
## Falsifying mutations: dropping the `tree:1` retry in `fetchHistory` loses
## the event for both shapes; giving the retry the whole byte limit again
## lets the history of the last test through.

import std/[base64, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator

import ./generator_fixtures

const
  Day = 86_400'u64
  T1 = 1_790_000_000'u64

suite "NPC-M11: a tag at a tree does not hide a history rewrite":

  for annotated in [false, true]:
    test "force-push plus " & (if annotated: "an annotated" else: "a lightweight") & " tag at a tree: history-rewritten is recorded":
      let f = newFixture("m11-treetag")
      let repo = f.newRepo("nim/victim.git")
      let c1 = repo.commit(@[nimbleFile("victim"),
        file("src/victim.nim", "proc v*(): int = 1\n")])
      repo.tag("v1.0.0")
      repo.publish()
      let reg = f.newRepo("nim-lang/packages.git")
      let rc = reg.commit(@[packagesJson(@[("victim", f.url("nim/victim.git"))])])
      reg.publish()
      let ss = parseSourceSet(sourceSetText(f.url("nim-lang/packages.git"),
        rc), "s.toml")
      let work = createTempDir("npc-m11-treetag-", "")
      let g1 = generate(f.genConfig(ss, T1, work / "state",
        outputDir = work / "g1"))
      check g1.built.envelopeOf("victim").versions.len == 1

      # Rewrite: `main` replaced by unrelated history, `v1.0.0` deleted,
      # and a tag at the new commit's tree.
      discard git(repo, "checkout", "-q", "--orphan", "rewritten")
      discard repo.commit(@[nimbleFile("victim"),
        file("src/victim.nim", "proc v*(): int = 2\n")], date = 1_700_300_000)
      discard git(repo, "branch", "-M", "rewritten", "main")
      discard git(repo, "tag", "-d", "v1.0.0")
      let tree = git(repo, "rev-parse", "HEAD^{tree}")
      if annotated:
        discard git(repo, "tag", "-a", "-m", "a tree", "notes", tree)
      else:
        discard git(repo, "tag", "notes", tree)
      repo.publish()

      let g2 = generate(f.genConfig(ss, T1 + Day, work / "state",
        previous = work / "g1", outputDir = work / "g2"))
      var events: seq[string]
      for e in g2.events:
        events.add $e.kind & " " & e.version & " " & e.before
      checkpoint events.join("\n")
      checkpoint g2.diagnostics.join("\n")
      check ("history-rewritten v1.0.0 " & c1) in events
      check ("tag-removed v1.0.0 " & c1) in events
      # The record is kept as it was.
      let kept = g2.built.envelopeOf("victim").versions
      var old = 0
      for v in kept:
        if v.commit == c1: inc old
      check old == 1

  test "the retry gets only what the first attempt left of the byte limit":
    # Commits of about 420 KiB (incompressible messages, in pieces under
    # the kernel's argument size limit) and a 640 KiB limit: one transfer
    # of the commits fits, two do not.
    let f = newFixture("m11-treetag-budget")
    let repo = f.newRepo("nim/heavy.git")
    for i in 0 ..< 8:
      discard repo.commit(@[nimbleFile("heavy")],
        message = encode(randomBytes(52_000, 1100 + i)),
        date = 1_700_000_000 + i)
    repo.publish()
    let g = OriginGit(gitBin: f.gitBin, caFile: f.cert)
    var limits = DefaultLimits
    limits.maxBytes = 640 * 1024
    let v = vetOrigin(f.testPolicy(limits), f.url("nim/heavy.git"))
    # Control: without a tree tag the commits-only fetch fits the limit.
    let plain = fetchHistory(g, v, createTempDir("npc-m11-budget-", ""),
      limits)
    check plain.ok
    check plain.branchCommits.len == 8
    # A tag at a tree: the first attempt fails after taking the commits,
    # and the retry, which would take them again, is cut at what is left.
    discard git(repo, "tag", "notes", git(repo, "rev-parse", "HEAD^{tree}"))
    repo.publish()
    var refused = ""
    try:
      let h = fetchHistory(g, v, createTempDir("npc-m11-budget-", ""), limits)
      checkpoint "ok=" & $h.ok & " " & h.failure
    except EgressError as e:
      refused = $e.refusal.kind
    check refused == $erSize

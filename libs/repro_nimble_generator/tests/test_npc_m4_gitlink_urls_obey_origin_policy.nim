## NPC-M4 verification `test_npc_m4_gitlink_urls_obey_origin_policy`
## (threat model G35, spec § 14).
##
## A tag with gitlinks is flagged `gitlinks`, and no `.gitmodules` URL is
## fetched outside the origin egress policy: an `ext::` URL whose helper
## would write a canary, and a `file://` URL naming a repository on this
## host, are never contacted -- nor is an `https` one, since no gitlink is
## fetched in this version. This holds whichever way operator question A4 on
## NPC-AREQ12 is decided: the URLs are classified by the policy and
## recorded, and the only path to the transport is the policy's.

import std/[os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

var attempted: seq[string]

suite "NPC-M4: gitlink URLs obey the origin policy":

  test "gitlinks are flagged; ext::, file:// and https submodule URLs are never contacted":
    let f = newFixture("gitlinks")
    let hostRepo = f.newRepo("host/private.git")
    let hostCommit = hostRepo.commit(@[file("secret.txt", "s\n")])
    hostRepo.publish()
    let sub = f.newRepo("nim/sub.git")
    let subCommit = sub.commit(@[file("c.h", "int x;\n")])
    sub.publish()
    let canary = f.dir / "ext-helper-ran"
    let fileUrl = "file://" & f.root / "host/private.git"
    let extUrl = "ext::sh -c touch% " & canary
    let httpsUrl = f.url("nim/sub.git")
    let w = f.newRepo("nim/withsubs.git")
    discard w.commit(@[nimbleFile("withsubs"), file("src/withsubs.nim",
      "discard\n")])
    w.tag("v1.0.0")
    let gitmodules = "[submodule \"a\"]\n\tpath = vendor/a\n\turl = " &
      extUrl & "\n[submodule \"b\"]\n\tpath = vendor/b\n\turl = " & fileUrl &
      "\n[submodule \"c\"]\n\tpath = vendor/c\n\turl = " & httpsUrl & "\n"
    let linked = w.commit(@[nimbleFile("withsubs"), file("src/withsubs.nim",
      "discard\n"), file(".gitmodules", gitmodules),
      gitlinkTo("vendor/a", subCommit), gitlinkTo("vendor/b", hostCommit),
      gitlinkTo("vendor/c", subCommit)])
    w.tag("v2.0.0")
    w.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[("withsubs",
      f.url("nim/withsubs.git"))])])
    reg.publish()
    let work = createTempDir("npc-m4-gitlinks-run-", "")
    var cfg = f.genConfig(parseSourceSet(sourceSetText(
      f.url("nim-lang/packages.git"), regCommit), "s.toml"), 1_790_000_000,
      work / "state")
    cfg.observer = proc(family: EdgeFamily; url: string) {.gcsafe.} =
      {.cast(gcsafe).}: attempted.add url
    let g = generate(cfg)

    for v in g.built.envelopeOf("withsubs").versions:
      if v.commit == linked:
        check flGitlinks in v.flags
      else:
        check flGitlinks notin v.flags
    # Every URL handed to the transport is an origin of the source set.
    for u in attempted:
      check u in [f.url("nim-lang/packages.git"), f.url("nim/withsubs.git")]
    check extUrl notin attempted
    check fileUrl notin attempted
    check httpsUrl notin attempted
    check not fileExists(canary)
    for line in f.requests():
      check "/nim/sub.git" notin line
      check "private" notin line
    # The policy's verdict on each URL is recorded.
    var verdicts: seq[string]
    for d in g.diagnostics:
      if "gitlink" in d: verdicts.add d
    checkpoint verdicts.join("\n")
    check verdicts.len == 3
    var sawExt, sawFile, sawHttps = false
    for d in verdicts:
      if "vendor/a" in d and d.endsWith("refused:scheme"): sawExt = true
      if "vendor/b" in d and d.endsWith("refused:scheme"): sawFile = true
      if "vendor/c" in d and d.endsWith("not-fetched"): sawHttps = true
    check sawExt
    check sawFile
    check sawHttps

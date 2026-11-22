## NPC-M13 verification `test_npc_m13_egress_refused_submodule_url_refused`
## (threat model G37, T6).
##
## Five packages, each with one gitlink whose `.gitmodules` URL the origin
## egress policy refuses:
##
## * `file:///<canary repository>` (a repository on this host);
## * `ext::sh -c touch% <canary file>` (a remote helper that would run);
## * `http://forge.test/...` (plain http, to a host that serves the
##   submodule over https);
## * `https://internal.test/...`, whose host resolves to 127.0.0.1;
## * `../../../internal.test:<port>/...`, a relative URL that git resolves
##   past the superproject's host to the same loopback origin.
##
## Each version gets no record and one `gone` event naming the submodule and
## "refused by the egress policy". Nothing is contacted: a URL rule 1
## refuses is never handed to a transport (the observer never sees it), the
## loopback one is refused by its address before any connection (the
## listener sees no request for the submodule), the helper never runs, and
## the canary repository is never handed to git. The client's git fallback
## refuses the same URLs for a hand-made lock row (no index record).
##
## Falsifying mutation: skipping the egress classification of submodule URLs
## hands the `file://` URL to the transport.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index

import ./fetch_fixtures
import ../../repro_nimble_generator/tests/submodule_fixtures

var attempted: seq[string]
var clientSaw: seq[string]

suite "NPC-M13: a submodule URL the egress policy refuses is refused":
  test "file://, ext::, http://, a loopback https host and a relative URL to it: not offered, never contacted":
    let f = newFixture("m13-egress")
    let work = createTempDir("npc-m13-egress-", "")
    let canaryRepo = f.dir / "canary.git"
    discard run(["git", "init", "-q", "--bare", canaryRepo], env = gitEnv())
    let canaryFile = f.dir / "ext-helper-ran"
    let (_, subCommit) = f.served("nim/sub.git", @[file("sub.c", "int s;\n")])
    let port = $f.port
    let cases = @[
      ("pfile", "file://" & canaryRepo),
      ("pext", "ext::sh -c touch% " & canaryFile),
      ("phttp", "http://forge.test:" & port & "/nim/sub.git"),
      ("ploop", "https://internal.test:" & port & "/nim/sub.git"),
      ("prel", "../../../internal.test:" & port & "/nim/sub.git")]
    var pkgs: seq[(string, string)]
    var commits: seq[string]
    for (name, url) in cases:
      let (_, c) = f.served("nim/" & name & ".git", @[nimbleFile(name),
        file("src/" & name & ".nim", "discard\n"),
        gitmodules(@[("vendor/s", url)]), gitlinkTo("vendor/s", subCommit)],
        tags = @["v1.0.0"])
      commits.add c
      pkgs.add (name, f.url("nim/" & name & ".git"))
    let reg = f.registryOf(pkgs)
    let observer = proc(family: EdgeFamily; url: string) {.gcsafe.} =
      {.cast(gcsafe).}: attempted.add url
    let g = f.generation(reg, 1_790_000_000, work / "state",
      observer = observer)
    checkpoint "events: " & $g.events
    checkpoint "attempted: " & attempted.join("\n")
    checkpoint "diagnostics: " & g.diagnostics.join("\n")
    for i, (name, url) in cases:
      check not g.built.hasPackage(name)
      let gone = g.goneOf(name)
      check gone.len == 1
      if gone.len == 1:
        check gone[0].version == "v1.0.0"
        check gone[0].before == commits[i]
        check gone[0].after == "submodule vendor/s: refused by the egress policy"
    # Rule 1 refusals are never handed to a transport; the loopback host is
    # vetted (resolved, never connected to).
    for u in attempted:
      check "canary" notin u
      check not u.startsWith("ext::")
      check not u.startsWith("http://")
      check not u.startsWith("file://")
    check f.url("nim/sub.git", host = "internal.test") in attempted
    check not fileExists(canaryFile)
    for line in f.requests():
      check "/nim/sub.git" notin line
      check "internal.test" notin line
    check g.executedOf(efSubmodule).len == 1
    for s in g.executedOf(efSubmodule):
      check s.startsWith(f.url("nim/sub.git", host = "internal.test"))
    var refused: seq[string]
    for r in g.refusals:
      refused.add r.package & " " & $r.refusal.kind
      # A captured refusal names the URL refused, not the submodule's path.
      check r.refusal.url != "vendor/s"
      if r.package == "pfile":
        check r.refusal.url == "file://" & canaryRepo
    checkpoint "refusals: " & refused.join(", ")
    for name in ["pfile", "pext", "phttp"]:
      check (name & " scheme") in refused
    check ("ploop address") in refused or ("prel address") in refused

    # The client's git fallback, for hand-made lock rows of the same
    # commits: the forge archive is not configured, so git is the only
    # transport, and it refuses each submodule URL.
    let before = f.requests().len
    for i, (name, url) in cases:
      let row = NimbleLockRow(name: name, origin: f.url("nim/" & name & ".git"),
        commit: commits[i], tree: repeat('0', 64), size: -1)
      var cfg = f.fetchConfig(work / ("client-" & name), @[])
      cfg.forges = @[]
      cfg.observer = proc(t: Transport; u: string) {.gcsafe.} =
        {.cast(gcsafe).}: clientSaw.add u
      let fr = fetchLocked(@[row], cfg)
      check not fr.ok
      require fr.packages.len == 1
      let p = fr.packages[0]
      checkpoint name & " attempts: " & $p.attempts
      check p.state == psFailed
      require p.attempts.len == 1
      check p.attempts[0].transport == tGit
      check p.attempts[0].outcome == aoRefused
      check p.attempts[0].detail.startsWith(
        "submodule vendor/s: refused by the egress policy")
      check p.attempts[0].rule == (if name in ["ploop", "prel"]: "address"
                                   else: "scheme")
    checkpoint "client saw: " & clientSaw.join("\n")
    for u in clientSaw:
      check "canary" notin u
      check not u.startsWith("ext::")
      check not u.startsWith("http://")
    check not fileExists(canaryFile)
    for line in f.requests()[before .. ^1]:
      check "/nim/sub.git" notin line

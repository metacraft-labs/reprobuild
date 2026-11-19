## Threat model G5 (CONF-6), the client's half: the origin fallback of
## `nimble.fetch` follows the same egress policy as the generator's origin
## fetches (`repro_nimble_generator/egress`), for the forge archive and for
## git alike.
##
## With no mirror holding the sources, lock rows whose origin is not `https`
## (`file://`, `http://`, `ssh://`, `git://`, `ext::`), whose host resolves to
## a loopback, private, link-local or metadata address, or whose forge
## archive redirects to a loopback name, are each refused with the policy's
## reason before any connection to such an address; a plain `https` forge
## origin is fetched (positive control). The loopback name `internal.test`
## really resolves to 127.0.0.1, where the fixture listens, so a policy that
## let it through would show up as a request on the fixture.
##
## The policy's time limit holds for the forge archive too: an origin that
## sends its archive slowly but steadily, never stalling, is cut at the wall
## time and refused `timeout`, long before it would have finished.
##
## No mock: the production egress policy, with the fixture's resolver and
## dialer (see `generator_fixtures`), over real HTTPS.

import std/[os, strutils, tempfiles, times, unittest]

import ./fetch_fixtures

suite "NPC-M5: the origin fallback obeys the egress policy":
  test "non-https and non-public origins are refused; a forge origin is fetched":
    let f = newFixture("fallback-egress", @[
      Route(prefix: "/owner/redir/archive/",
        redirectTo: "https://internal.test:{port}/loop/redir.tar.gz"),
      Route(prefix: "/", forgeArchives: true)])
    let work = createTempDir("npc-m5-fallback-", "")
    let good = f.package("owner/good.git", @[nimbleFile("good"),
      file("src/good.nim", "\n")])
    # The same repository served under the loopback path, so that a fetch
    # that got through to 127.0.0.1 would find something to take.
    let loopRepo = f.root / "loop" / "good.git"
    createDir(parentDir(loopRepo))
    copyDir(f.root / "owner/good.git", loopRepo)
    let canary = work / "ext-ran"
    let port = $f.port
    let bad = @[
      ("file", "file://" & f.root / "owner/good.git", "scheme"),
      ("http", "http://" & ForgeHost & ":" & port & "/owner/good.git", "scheme"),
      ("ssh", "ssh://git@" & ForgeHost & "/owner/good.git", "scheme"),
      ("git", "git://" & ForgeHost & "/owner/good.git", "scheme"),
      ("ext", "ext::sh -c touch% " & canary, "scheme"),
      ("loopback", "https://internal.test:" & port & "/loop/good.git", "address"),
      ("private", "https://private.test:" & port & "/loop/good.git", "address"),
      ("linklocal", "https://linklocal.test:" & port & "/loop/good.git", "address"),
      ("metadata", "https://metadata.test:" & port & "/loop/good.git", "address"),
      ("literal", "https://127.0.0.1:" & port & "/loop/good.git", "address")]
    for (label, origin, reason) in bad:
      let row = NimbleLockRow(name: label, origin: origin,
        commit: good.commit, tree: good.tree, size: -1)
      let r = fetchLocked(@[row], f.fetchConfig(work / label, @[]))
      checkpoint label & " " & origin
      check not r.ok
      check r.packages[0].attempts.len > 0
      for a in r.packages[0].attempts:
        checkpoint $a.transport & ": " & $a.outcome & " " & a.rule & " " &
          a.detail
        check a.outcome == aoRefused
        check a.rule == reason
      check not dirExists(work / label / "store" / good.tree)
    # The redirect: the forge answers the archive request with a 302 to the
    # loopback name; the target is vetted and refused, never contacted.
    let redirRow = NimbleLockRow(name: "redir",
      origin: f.url("owner/redir.git"), commit: good.commit, tree: good.tree,
      size: -1)
    let rr = fetchLocked(@[redirRow], f.fetchConfig(work / "redir", @[]))
    check not rr.ok
    var forgeAttempt: FetchAttempt
    for a in rr.packages[0].attempts:
      if a.transport == tForgeArchive: forgeAttempt = a
    checkpoint forgeAttempt.detail
    check forgeAttempt.outcome == aoRefused
    check forgeAttempt.rule == "address"
    check "internal.test" in forgeAttempt.detail
    # Nothing reached the loopback path, and the ext:: helper never ran.
    check f.requestsMatching("/loop/") == 0
    check not fileExists(canary)

    # Positive control: the plain https forge origin is fetched by its archive.
    let ok = fetchLocked(@[f.rowOf("good", good, withArchive = false)],
      f.fetchConfig(work / "good", @[]))
    check ok.ok
    check ok.packages[0].transport == tForgeArchive
    check f.requestsMatching("GET /owner/good/archive/") == 1

  test "an origin archive that trickles is cut at the wall-time limit":
    let f = newFixture("fallback-drip")
    let server = f.newConcurrentMirror(createTempDir("npc-m5-drip-dir-", ""),
      dripMs = 100)
    let work = createTempDir("npc-m5-drip-", "")
    var limits = DefaultLimits
    limits.wallSeconds = 2
    limits.stallSeconds = 5
    var cfg = f.fetchConfig(work, @[])
    cfg.originPolicy = f.testPolicy(limits)
    # 2 MiB at 8 KiB per 100 ms: about 26 s to finish, and every 64 KiB
    # read completes in under a second, so the stall limit never fires.
    let row = NimbleLockRow(name: "drip",
      origin: "https://" & ForgeHost & ":" & $server.port & "/drip/pkg.git",
      commit: repeat('a', 40), tree: repeat('b', 64), size: -1)
    let started = epochTime()
    let r = fetchLocked(@[row], cfg)
    let took = epochTime() - started
    check not r.ok
    var forgeAttempt: FetchAttempt
    for a in r.packages[0].attempts:
      if a.transport == tForgeArchive: forgeAttempt = a
    checkpoint forgeAttempt.detail
    check server.requests().len > 0
    check server.requests()[0].startsWith("GET /drip/pkg/archive/")
    check forgeAttempt.outcome == aoRefused
    check forgeAttempt.rule == "timeout"
    check took < 15.0

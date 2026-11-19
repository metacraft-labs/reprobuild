## NPC-M4 verification `test_npc_m4_origin_fetch_egress_policy` (threat
## model G5, CONF-6).
##
## Origins named `file://`, `ssh://`, `git://`, `http://` and `ext::`; names
## resolving to a loopback, private, link-local and metadata address; an
## `https` origin redirecting to a loopback name; an oversize pack and a
## stalled transfer: each is refused, with the refusal captured against its
## package, and none is indexed. A plain `https` forge origin is fetched
## (the positive control), through the same generation and the same policy
## code.
##
## The origins are served over real HTTPS from 127.0.0.1. The test's
## resolver answers a documentation address (never routed) for the forge's
## name, which the policy checks like any public address, and the test's
## dialer connects that address to the local listener; every other address
## is the resolver's answer, checked and refused before any connection.

import std/[net, os, strtabs, strutils, tables, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

suite "NPC-M4: origin fetches follow the egress policy":

  test "bad schemes, internal addresses, a redirect, oversize and stall are refused; https is fetched":
    let f = newFixture("egress", @[
      Route(prefix: "/redirect/", redirectTo:
        "https://internal.test:{port}/nim/good.git/info/refs?service=git-upload-pack"),
      Route(prefix: "/stall/", stall: true)])
    let good = f.newRepo("nim/good.git")
    discard good.commit(@[nimbleFile("good"), file("src/good.nim", "discard\n")])
    good.tag("v1.0.0")
    good.publish()
    let big = f.newRepo("nim/big.git")
    discard big.commit(@[nimbleFile("big"), file("src/big.nim", "discard\n"),
      file("blob.bin", randomBytes(3 * 1024 * 1024, 7))])
    big.tag("v1.0.0")
    big.publish()
    # A host path a `file://` origin would clone, if it were ever fetched.
    let hostRepo = f.newRepo("host/secret.git")
    discard hostRepo.commit(@[nimbleFile("secret"), file("src/secret.nim",
      "discard\n")])
    hostRepo.tag("v9.9.9")
    hostRepo.publish()
    let canary = f.dir / "ext-ran"
    let origins = @[
      ("good", f.url("nim/good.git")),
      ("big", f.url("nim/big.git")),
      ("viafile", "file://" & f.root / "host/secret.git"),
      ("viassh", "ssh://git@forge.test/nim/good.git"),
      ("viagit", "git://forge.test/nim/good.git"),
      ("viahttp", "http://forge.test:" & $f.port & "/nim/good.git"),
      ("viaext", "ext::sh -c touch% " & canary),
      ("viascp", "git@forge.test:nim/good.git"),
      ("viacreds", "https://user:token@forge.test:" & $f.port & "/nim/good.git"),
      ("loopback", f.url("nim/good.git", host = "internal.test")),
      ("private", f.url("nim/good.git", host = "private.test")),
      ("linklocal", f.url("nim/good.git", host = "linklocal.test")),
      ("metadata", f.url("nim/good.git", host = "metadata.test")),
      ("literal", "https://127.0.0.1:" & $f.port & "/nim/good.git"),
      ("mapped", "https://[::ffff:169.254.169.254]:" & $f.port & "/nim/good.git"),
      ("redirected", f.url("redirect/good.git")),
      ("stalled", f.url("stall/good.git"))]
    var extras = ""
    for (n, u) in origins:
      extras.add "\n[[extra]]\nname = " & n.escape() & "\norigin = " &
        u.escape() & "\n"
    let ss = parseSourceSet("schema = \"reprobuild.nimble-source-set.v1\"\n" &
      extras, "s.toml")
    var limits = DefaultLimits
    limits.maxBytes = 1024 * 1024
    limits.stallSeconds = 3
    limits.wallSeconds = 60
    let work = createTempDir("npc-m4-egress-run-", "")
    let g = generate(f.genConfig(ss, 1_790_000_000, work / "state",
      limits = limits))

    var refusals = initTable[string, EgressRefusal]()
    for r in g.refusals:
      if r.package notin refusals: refusals[r.package] = r.refusal
    checkpoint "refusals: " & $refusals
    let expected = {
      "viafile": erScheme, "viassh": erScheme, "viagit": erScheme,
      "viahttp": erScheme, "viaext": erScheme, "viascp": erScheme,
      "viacreds": erCredentials,
      "loopback": erAddress, "private": erAddress, "linklocal": erAddress,
      "metadata": erAddress, "literal": erAddress, "mapped": erAddress,
      "redirected": erAddress, "stalled": erStall, "big": erSize}.toTable
    for name, kind in expected:
      check name in refusals
      if name in refusals:
        check refusals[name].kind == kind
    check refusals["loopback"].addressClass == acLoopback
    check refusals["private"].addressClass == acPrivate
    check refusals["linklocal"].addressClass == acLinkLocal
    check refusals["metadata"].addressClass == acMetadata
    check refusals["mapped"].addressClass == acMetadata
    check refusals["redirected"].url.startsWith("https://internal.test:")
    # None of them is indexed; each is observed as refused.
    for name in expected.keys:
      if name != "big":
        check not g.built.hasPackage(name)
        check g.built.observationOf(name).state == osRefused
    # The oversize pack: its refs answered, its source was refused.
    check g.built.observationOf("big").state == osAnswering
    check not g.built.hasPackage("big")
    # Nothing reached the internal names, and the ext:: helper never ran.
    check not fileExists(canary)
    for line in f.requests():
      check "secret" notin line
    var redirectHits, stallHits = 0
    for line in f.requests():
      if line.startsWith("GET /redirect/"): inc redirectHits
      if line.startsWith("GET /stall/"): inc stallHits
    check redirectHits == 1  # the discovery request; never followed
    check stallHits >= 1

    # Positive control: the https forge origin is fetched and indexed.
    check "good" notin refusals
    check g.built.hasPackage("good")
    check g.built.envelopeOf("good").versions.len == 1

  test "the git layer refuses a non-https transport on its own":
    # The second layer: even an origin the policy did not see is fetched
    # by git with only https allowed.
    let f = newFixture("egress-git")
    let w = f.newRepo("host/secret.git")
    discard w.commit(@[nimbleFile("secret")])
    w.publish()
    let g = OriginGit(gitBin: f.gitBin, caFile: f.cert)
    let scratch = createTempDir("npc-m4-egress-git-", "")
    # The worker's git holds nothing of this process's environment: no
    # credential, proxy or git configuration variable reaches it.
    for (k, v) in [("GITHUB_TOKEN", "t0k3n"), ("GIT_ASKPASS", "/bin/echo"),
                   ("https_proxy", "http://proxy.invalid:3128"),
                   ("GIT_CONFIG_PARAMETERS", "'protocol.allow'='always'")]:
      putEnv(k, v)
    let env = gitEnvironment(g, scratch / "home")
    for k in ["GITHUB_TOKEN", "GIT_ASKPASS", "https_proxy",
              "GIT_CONFIG_PARAMETERS", "SSH_AUTH_SOCK"]:
      check not env.hasKey(k)
    check env["GIT_ALLOW_PROTOCOL"] == "https"
    let r = runBounded(g, @["ls-remote", "file://" & f.root / "host/secret.git"],
      scratch, scratch / "home", DefaultLimits)
    check r.code != 0
    check "not allowed" in r.stderrText
    # Positive control through the same runner: https to the forge.
    let v = vetOrigin(f.testPolicy(), f.url("host/secret.git"))
    let ls = lsRemote(g, v, scratch / "ls", DefaultLimits)
    check ls.ok
    check ls.answer.head.len == 40

  test "address classes":
    for (a, c) in [("127.0.0.1", acLoopback), ("10.0.0.1", acPrivate),
                   ("172.31.255.255", acPrivate), ("172.32.0.1", acPublic),
                   ("192.168.1.1", acPrivate), ("100.64.0.1", acShared),
                   ("169.254.169.254", acMetadata), ("169.254.1.1", acLinkLocal),
                   ("0.0.0.0", acUnspecified), ("224.0.0.1", acMulticast),
                   ("255.255.255.255", acBroadcast), ("240.0.0.1", acReserved),
                   ("8.8.8.8", acPublic), ("203.0.113.10", acPublic),
                   ("::1", acLoopback), ("::", acUnspecified),
                   ("fe80::1", acLinkLocal), ("fd00:ec2::254", acMetadata),
                   ("fc00::1", acPrivate), ("::ffff:127.0.0.1", acLoopback),
                   ("64:ff9b::a00:1", acPrivate), ("2002:7f00:1::", acLoopback),
                   ("64:ff9b:1::a00:1", acReserved),
                   ("64:ff9b:1:abcd::808:808", acReserved),
                   ("64:ff9b::808:808", acPublic),
                   ("ff02::1", acMulticast), ("2001:db8::1", acPublic),
                   ("2606:4700::1111", acPublic)]:
      checkpoint a
      check classifyAddress(parseIpAddress(a)) == c

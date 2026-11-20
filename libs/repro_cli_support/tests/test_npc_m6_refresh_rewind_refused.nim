## NPC-M6 verification `test_npc_m6_refresh_rewind_refused` (NPC-AREQ15,
## threat model G14): refreshing a `nimble-index` import whose ref now names
## a revision that does not descend from the lock's pin is refused, and the
## lock is left byte-identical; `--allow-rewind=<import>` accepts it and
## says so. A forward move needs no flag (control).
##
## The rewind is real git history: the index repository's `main` is reset to
## an older generation and the shared clone fetched with `--force`, as a
## mirror or a hostile remote serving an older, validly attributed revision
## would leave it. The ancestry is checked from the commit objects.
##
## Falsifying mutation (recorded in the plan): `rewindCheck` returning ""
## (no ancestry check) accepts the rewound revision without the flag.
##
## No mock: real git repositories, the production lock verbs in process.

import std/[os, strutils, unittest]

import ./nimble_m6_fixtures

suite "NPC-M6: a catalog refresh cannot go backwards":
  test "a rewound ref is refused; --allow-rewind accepts it; forward is free":
    var w = newWorld("rewind")
    let pkg1 = @[package("alpha", @[record("alpha", "1.0.0")])]
    let pkg2 = @[package("alpha", @[record("alpha", "1.0.0"),
      record("alpha", "1.1.0")])]
    let gen1 = w.publish(pkg1, daysAgo(10), "generation 1")
    let gen2 = w.publish(pkg2, daysAgo(5), "generation 2")
    let dir = w.newProject(@[("alpha", "")])

    let first = refreshProvisioning(dir)
    checkpoint first.output
    check first.rc == 0
    check indexPin(dir).revision == gen2.commit
    check nimbleRows(dir)["nimble:alpha"].version == "1.1.0"
    let pinned = readFile(dir / "repro.lock")

    # The remote now serves generation 1 under `main`.
    w.resetMain(gen1.commit)
    let refused = refreshProvisioning(dir)
    checkpoint refused.output
    check refused.rc != 0
    check "does not descend from the pinned revision " & gen2.commit in
      refused.output
    check "--allow-rewind=" & IndexRepo in refused.output
    check readFile(dir / "repro.lock") == pinned

    # Named, it is accepted, and the acceptance is reported.
    let allowed = refreshProvisioning(dir, @["--allow-rewind=" & IndexRepo])
    checkpoint allowed.output
    check allowed.rc == 0
    check "accepted because --allow-rewind names \"" & IndexRepo & "\"" in
      allowed.output
    check indexPin(dir).revision == gen1.commit
    check nimbleRows(dir)["nimble:alpha"].version == "1.0.0"

    # Forward again (a new generation on top): no flag needed.
    let gen3 = w.publish(pkg2, daysAgo(1), "generation 3")
    let forward = refreshProvisioning(dir)
    checkpoint forward.output
    check forward.rc == 0
    check indexPin(dir).revision == gen3.commit

  test "--allow-rewind without --provisioning is a usage error":
    var w = newWorld("rewind-usage")
    discard w.publish(@[package("alpha", @[record("alpha", "1.0.0")])],
      daysAgo(1), "generation 1")
    let dir = w.newProject(@[("alpha", "")])
    let r = lockVerb(dir, "refresh", @["--allow-rewind=" & IndexRepo])
    check r.rc == 2
    check "add --provisioning" in r.output

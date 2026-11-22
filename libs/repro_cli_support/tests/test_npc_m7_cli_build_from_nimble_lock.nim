## NPC-M7: a real `repro build` of a lock with `nimble:` rows (NPC-AREQ19,
## NPC-AREQ20, NPC-AREQ21), cold and then warm with the network denied.
##
## 1. `repro lock refresh --provisioning` pins the index and writes the
##    rows of `nimble:alpha` and the `nimble:beta` it requires.
## 2. A cold `repro build` fetches both trees from the mirror the index
##    repository's `nimble-sources.toml` declares (the fixture's HTTPS
##    listener), and the project's `nim.c` edge compiles `import alpha`,
##    which imports `beta`: neither is on any path the project wrote, so
##    the compile resolves them only through the `--path:` roots the build
##    hands it from the store. The program runs and writes what the two
##    packages return.
## 3. The same build again, warm, with every source location gone: the
##    mirror's objects are deleted and both origins are no longer served, so
##    a build that tried to fetch anything would fail. It succeeds, and the
##    fixture (the only listener the build could reach) logged no request.
##
## Why not a network namespace: under `unshare -c -n` (a user namespace
## mapping only the caller's uid), `/` belongs to the overflow uid, and
## `repro` rightly refuses its per-user caches below a directory another
## account owns ("refusing the interface-extraction nimcache directory").
##
## Positive control for 3: with one tree removed from the store, the same
## build tries the mirror, finds nothing, and fails naming the package --
## so "no request" is not "nothing needed".
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures

suite "NPC-M7: repro build from a lock with nimble: rows":
  test "cold build fetches and compiles; warm build needs no network":
    var w = newWorld("m7-cli")
    let mirrorDir = w.root / "mirror"
    createDir(mirrorDir)
    let f = newFixture("m7-cli",
      @[Route(prefix: "/mirror/", serveDir: mirrorDir)])
    let local = parseMirror(mirrorDir)
    let betaSrc = f.package("owner/beta.git", @[nimbleFile("beta"),
      file("src/beta.nim", "proc beta*(): string = \"BETA-M7-STAMP\"\n")])
    let alphaSrc = f.package("owner/alpha.git", @[nimbleFile("alpha"),
      file("src/alpha.nim",
        "import beta\nproc alpha*(): string = \"alpha+\" & beta()\n")])
    local.putSource(alphaSrc)
    local.putSource(betaSrc)
    let alpha = f.envelope("alpha", @[f.recordOf("alpha", alphaSrc,
      "v1.0.0", @[req("beta", ">= 1.0.0")])], alphaSrc)
    let beta = f.envelope("beta", @[f.recordOf("beta", betaSrc, "v1.0.0")],
      betaSrc)
    discard w.publish(@[alpha, beta], daysAgo(1), "generation 1",
      extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let dir = w.writeCliProject("app", @[("alpha", ">= 1.0.0")],
      "import alpha\nwriteFile(\"build/app-out.txt\", alpha())\n")
    let env = cliEnv(w, f)

    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    check locked.rc == 0
    check nimbleRows(dir).len == 2

    let cold = runRepro(env, dir, BuildArgs)
    checkpoint cold.output
    check cold.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "alpha+BETA-M7-STAMP"
    check f.requestsMatching(alphaSrc.tree) >= 1
    check f.requestsMatching(betaSrc.tree) >= 1
    let store = w.storeRootOf()
    check entryVerified(store, alphaSrc.tree)
    check entryVerified(store, betaSrc.tree)

    # Warm, every source location gone: nothing fetched, nothing requested.
    removeFile(dir / "build" / "app-out.txt")
    removeDir(mirrorDir)
    createDir(mirrorDir)
    f.deleteServed(alphaSrc.path)
    f.deleteServed(betaSrc.path)
    let before = f.requests().len
    let warm = runRepro(env, dir, BuildArgs)
    checkpoint warm.output
    check warm.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "alpha+BETA-M7-STAMP"
    check f.requests().len == before

    # Positive control: a tree the store lacks cannot be had now.
    removeDir(entryPath(store, betaSrc.tree))
    let starved = runRepro(env, dir, BuildArgs)
    checkpoint starved.output
    check starved.rc != 0
    check "nimble:beta" in starved.output
    # ...and it did try: the request count moved, so the warm build's
    # unchanged count is a fact about the build, not about the fixture.
    check f.requests().len > before

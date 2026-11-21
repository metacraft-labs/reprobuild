## NPC-AREQ29 claim 1, NPC-M6 verification `test_npc_resolve_spawns_no_git`:
## resolving a 30-package closure performs no git operation and spawns no
## process, and reads at most 30 shards plus the root.
##
## The lock already names the index root (it pins the import), so the
## resolution reads the root and the shards it needs from the local object
## cache, by hash (spec § 1.1, "Index by hash"), and the solve runs in
## process (clingo through its library). The pin is made first by a real
## `repro lock refresh --provisioning`, which reads the index repository
## through git and fills the cache as it goes.
##
## Spawns are observed from outside: during the resolution `PATH` holds
## only a directory whose `git` records every invocation and fails, so a
## git process -- or any other program found by name -- would be seen (or
## would fail the resolution). Shards are counted by the index reader's
## own decoded-shard table, and every object is read by hash.
##
## Falsifying mutation (recorded in the plan): resolving through the shared
## clone instead of the cache (``cachedNimbleIndexAt`` answering none) runs
## `git cat-file`, and the canary records it.
##
## No mock: a real index repository, the production verbs and solver.

import std/[os, strutils, tables, unittest]

import repro_solver/[version_encoder, variant_encoder, solver_api]

import ./nimble_m6_fixtures

const Closure = 30

proc closurePackages(): seq[PackageEnvelope] =
  ## `pkg00` requires `pkg01` ... `pkg29` (one level, so every name is read
  ## once); each has two versions; 400 more packages nothing requires keep
  ## the index sharded far wider than the closure.
  var reqs: seq[RequirementEntry]
  for i in 1 ..< Closure:
    reqs.add req("pkg" & align($i, 2, '0'), ">= 1.0.0")
  result.add package("pkg00", @[record("pkg00", "1.0.0", reqs)])
  for i in 1 ..< Closure:
    let n = "pkg" & align($i, 2, '0')
    result.add package(n, @[record(n, "1.0.0"), record(n, "1.1.0")])
  for i in 0 ..< 400:
    let n = "filler" & align($i, 3, '0')
    result.add package(n, @[record(n, "1.0.0")])

suite "NPC-M6: a resolution spawns no git and reads only what it needs":
  test "a 30-package closure: no process, at most 30 shards and the root":
    var w = newWorld("nogit")
    let gen = w.publish(closurePackages(), daysAgo(1), "generation 1")
    check gen.built.root.shards.len > Closure
    let dir = w.newProject(@[("pkg00", "")])
    let pinned = refreshProvisioning(dir)
    checkpoint pinned.output
    check pinned.rc == 0
    let pins = lockOf(dir).lockedCatalogImportPins()
    check pins.len == 1

    let canaryDir = w.root / "canary"
    createDir(canaryDir)
    let log = w.root / "spawned.log"
    writeFile(canaryDir / "git", "#!/bin/sh\necho \"git $*\" >> " &
      quoteShell(log) & "\nexit 1\n")
    setFilePermissions(canaryDir / "git", {fpUserRead, fpUserWrite,
      fpUserExec})
    let savedPath = getEnv("PATH")
    putEnv("PATH", canaryDir)
    var setup: NimbleSolveSetup
    var packages = @[newPackage("app", ["1.0.0"],
      [newDependency("nimble:pkg00", "")])]
    var sol: UnifiedSolution
    try:
      setup = prepareNimbleSolve(dir, packages, pins, reselect = false,
        allowRewind = @[], platform = currentPlatformId())
      let noVariants: seq[VariantDecl] = @[]
      sol = solve(noVariants, packages)
    finally:
      putEnv("PATH", savedPath)
    let spawned = if fileExists(log): readFile(log) else: ""
    checkpoint spawned
    check spawned.len == 0
    check setup.active
    check setup.index.revision == gen.commit
    check setup.input.packages.len == Closure
    check setup.shardsRead >= 1
    check setup.shardsRead <= Closure
    var chosen = 0
    for k, v in sol.packages:
      if k.startsWith("nimble:pkg"):
        inc chosen
        if k != "nimble:pkg00": check v == "1.1.0"
    check chosen == Closure

    # Control: the canary does catch git. A resolution that must read the
    # shared clone (the cache emptied) records an invocation and fails.
    removeDir(nimbleIndexObjectCache())
    putEnv("PATH", canaryDir)
    var failed = false
    try:
      var again = @[newPackage("app", ["1.0.0"],
        [newDependency("nimble:pkg00", "")])]
      discard prepareNimbleSolve(dir, again, pins, reselect = false,
        allowRewind = @[], platform = currentPlatformId())
    except CatchableError:
      failed = true
    finally:
      putEnv("PATH", savedPath)
    check failed or fileExists(log)

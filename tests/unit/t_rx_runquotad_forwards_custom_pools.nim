## RX pool-forwarding — a build declares its named pools to RunQuota,
## recipe-declared custom pools alongside the convention ``compile`` /
## ``fetch`` caps.
##
## ## Context
##
## M9.R.12.3 taught the ``runquotad`` spawn site to forward the two
## convention pools (``compile=8`` / ``fetch=2``) so convention-body
## actions whose ``pool`` field is set are admitted rather than denied.
## A ``repro.nim`` recipe can also declare its OWN pool via
## ``buildPool("<name>", <cap>)`` and route execute edges through it
## (``edge.testBinary.run(pool="<name>", poolUnits=1)``) to serialize
## resource-contending tests. Without the pool, its execute-edge lease hits
## ``lease request exceeds named-pool budget: nim_pty.pty-serial``.
##
## Until 2026-10-01 these went to the daemon as ``runquotad --pool`` flags,
## and only when this process spawned it: a flag pins the pool for the
## daemon's life (the host file and ``runquota config set pools.NAME`` could
## not change it), and a daemon somebody else started never heard of the
## pool. Now every build DECLARES the pools its graph uses on its own
## RunQuota session (``declareRunQuotaPools``), and the declaration sits under
## the host file (reprobuild-specs/RunQuota-Host-Configuration.md, "Pools a
## build declares"). ``runQuotaPoolDeclaration`` is what is declared.
##
## ## What this test pins
##
##   1. Custom recipe pools are declared, dotted / dashed names intact.
##   2. A convention pool an action uses but the graph does not declare is
##      declared at the convention figure (``compile=8``, ``fetch=2``).
##   3. A recipe re-declaration of a convention pool (``compile=16``) wins,
##      once: it is what the recipe asked for.
##   4. Any other undeclared pool an action uses is declared at the engine's
##      ``maxParallel``, the figure its own pool gate uses for it.
##   5. Deterministic shape: the graph's pools as declared, then the
##      undeclared ones sorted by name.
##   6. A graph with no pools and no pooled action declares nothing.
##
## ## Falsifiability
##
## Drop the graph's pools from ``runQuotaPoolDeclaration`` and (1) fails;
## drop the action scan and (2) and (4) fail.

import std/[unittest]

import repro_build_engine

proc pooled(id, poolName: string): BuildAction =
  ## Through the engine's own constructor, which keys the action on its
  ## governing lock; only the pool fields matter here.
  action(id, ["unused"], pool = poolName, poolUnits = 1'u32,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc pairs(declared: seq[tuple[name: string; capacity: uint32]]):
    seq[string] =
  for entry in declared:
    result.add(entry.name & "=" & $entry.capacity)

suite "RX — a build declares recipe pools to RunQuota":

  test "custom dotted/dashed pool is declared intact":
    let declared = runQuotaPoolDeclaration(
      [pool("nim_pty.pty-serial", 1'u32)],
      [pooled("t", "nim_pty.pty-serial")], 12'u32)
    check pairs(declared) == @["nim_pty.pty-serial=1"]

  test "a convention pool an action uses is declared at the convention cap":
    let declared = runQuotaPoolDeclaration([],
      [pooled("cc", "compile"), pooled("dl", "fetch")], 12'u32)
    check pairs(declared) == @["compile=8", "fetch=2"]

  test "recipe re-declaration overrides the convention cap, once":
    let declared = runQuotaPoolDeclaration(
      [pool("nim_pty.pty-serial", 1'u32), pool("compile", 16'u32)],
      [pooled("cc", "compile")], 12'u32)
    let names = pairs(declared)
    check "compile=16" in names
    check "compile=8" notin names
    var compileCount = 0
    for p in names:
      if p.len >= 8 and p[0 ..< 8] == "compile=":
        compileCount += 1
    check compileCount == 1

  test "an undeclared non-convention pool gets the engine's maxParallel":
    let declared = runQuotaPoolDeclaration([],
      [pooled("link", "host/linker")], 12'u32)
    check pairs(declared) == @["host/linker=12"]

  test "deterministic order: graph pools as declared, then sorted undeclared":
    let declared = runQuotaPoolDeclaration(
      [pool("zeta.pool", 3'u32), pool("nim_pty.pty-serial", 1'u32),
       pool("alpha.pool", 2'u32)],
      [pooled("b", "fetch"), pooled("a", "compile"),
       pooled("c", "alpha.pool")], 12'u32)
    check pairs(declared) == @[
      "zeta.pool=3", "nim_pty.pty-serial=1", "alpha.pool=2",
      "compile=8", "fetch=2"]

  test "no pools and no pooled action declares nothing":
    check runQuotaPoolDeclaration([], [action("plain", ["unused"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())],
      12'u32).len == 0

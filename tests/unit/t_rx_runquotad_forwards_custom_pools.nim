## RX pool-forwarding — ``runquotad`` spawn forwards recipe-declared
## custom pools alongside the convention ``compile`` / ``fetch`` caps.
##
## ## Context
##
## M9.R.12.3 taught the ``runquotad`` spawn site to forward the two
## convention pools (``compile=8`` / ``fetch=2``) so convention-body
## actions whose ``pool`` field is set are admitted rather than denied.
## But a ``repro.nim`` recipe can also declare its OWN pool via
## ``buildPool("<name>", <cap>)`` and route execute edges through it
## (``edge.testBinary.run(pool="<name>", poolUnits=1)``) to serialize
## resource-contending tests. Those custom pools reach the CLI as
## ``buildGraph.pools`` entries in the extracted project graph.
##
## Before this fix ``startAutoRunQuotaIfNeeded`` hardcoded only the two
## convention pools, so a custom pool such as ``nim_pty.pty-serial``
## never reached the daemon. Its execute-edge lease hit
## ``lease request exceeds named-pool budget: nim_pty.pty-serial`` and
## the engine's ``automaticMonitor`` retry loop spun forever —
## ``repro build`` hung.
##
## ## What this test pins
##
## The fix routes all argv construction through the exported
## ``assembleRunquotadPoolArgs(extraPools)``. This test drives that real
## proc (no inline replica) and asserts:
##
##   1. Every convention pool is still forwarded (``fetch=2`` present).
##   2. Custom recipe pools are forwarded too (``nim_pty.pty-serial=1``),
##      dotted / dashed names surviving intact.
##   3. A recipe re-declaration of a convention pool (``compile=16``)
##      OVERRIDES the default 8 — the recipe cap wins, because that is
##      what the engine's in-process ``poolCapacity`` gate uses and the
##      daemon budget must match it.
##   4. Deterministic shape: the two convention pools come first (in the
##      historical M9.R.12.3 order), then custom pools sorted by name.
##
## ## Falsifiability
##
## Revert ``assembleRunquotadPoolArgs`` to emit only the hardcoded
## ``compile`` / ``fetch`` pair (ignoring ``extraPools``) and assertion
## (2) fails — the custom ``nim_pty.pty-serial=1`` flag is absent.
## Restore the forwarding and the test passes.

import std/[unittest]

import repro_cli_support
import repro_build_engine

proc poolPairs(argv: seq[string]): seq[string] =
  ## Collapse ``["--pool", "a=1", "--pool", "b=2"]`` to ``["a=1", "b=2"]``
  ## and assert the flag/value alternation the daemon parser expects.
  var i = 0
  while i < argv.len:
    check argv[i] == "--pool"
    check i + 1 < argv.len
    result.add(argv[i + 1])
    i += 2

suite "RX — runquotad spawn forwards recipe-declared custom pools":

  test "convention fetch pool is still forwarded":
    let argv = assembleRunquotadPoolArgs(@[
      pool("nim_pty.pty-serial", 1'u32)
    ])
    check "--pool" in argv
    let pairs = poolPairs(argv)
    check "fetch=2" in pairs
    check "compile=8" in pairs

  test "custom dotted/dashed pool is forwarded intact":
    let argv = assembleRunquotadPoolArgs(@[
      pool("nim_pty.pty-serial", 1'u32)
    ])
    let pairs = poolPairs(argv)
    check "nim_pty.pty-serial=1" in pairs

  test "recipe re-declaration overrides the convention cap (cap wins)":
    let argv = assembleRunquotadPoolArgs(@[
      pool("nim_pty.pty-serial", 1'u32),
      pool("compile", 16'u32)
    ])
    let pairs = poolPairs(argv)
    # The widened recipe value must win; the default 8 must NOT appear.
    check "compile=16" in pairs
    check "compile=8" notin pairs
    # A single compile entry only — no duplicate flag.
    var compileCount = 0
    for p in pairs:
      if p.len >= 8 and p[0 ..< 8] == "compile=":
        compileCount += 1
    check compileCount == 1

  test "deterministic order: convention pools first, then sorted custom":
    let argv = assembleRunquotadPoolArgs(@[
      pool("zeta.pool", 3'u32),
      pool("nim_pty.pty-serial", 1'u32),
      pool("alpha.pool", 2'u32)
    ])
    let pairs = poolPairs(argv)
    # Convention pools lead, in the historical M9.R.12.3 order.
    check pairs[0] == "compile=8"
    check pairs[1] == "fetch=2"
    # Custom pools follow, sorted by name.
    check pairs[2 .. ^1] == @[
      "alpha.pool=2", "nim_pty.pty-serial=1", "zeta.pool=3"]

  test "no extra pools yields exactly the two convention pools":
    let argv = assembleRunquotadPoolArgs(@[])
    let pairs = poolPairs(argv)
    check pairs == @["compile=8", "fetch=2"]

## S7 — a cacheable ``nim.c`` edge declares its nimcache as machine-local
## derived state, and declares the RIGHT one.
##
## Why a change to the ``nim.c`` alias belongs to a caching milestone.
##
## S7 makes ``repro build --restore-cached-outputs`` able to restore a
## deleted output from the local CAS instead of re-running the action that
## produced it. That substitution is sound only when an action's DECLARED
## outputs are the whole of its product: an action that also produces
## something it does not declare gets, under restore, a tree silently
## missing that something — and a reported cache HIT while it happens. The
## engine therefore gates the restore per action
## (``BuildEngineConfig.requireCompleteOutputEvidence``): it compares the
## monitor's record of what the action actually WROTE against what it
## declared, and any surviving file the declaration does not account for
## costs that action its output payloads, so its record can never serve a
## restore and it re-runs instead. The gate fails closed.
##
## ``nim c`` writes its whole incremental cache — the generated ``.c``, the
## ``.o``, the per-entry ``.json`` manifest — into its ``--nimcache:``
## directory, and the monitor records every one of those as a write.
##
## Measured through the real CLI, and this is the ONE measurement quoted
## wherever the milestone needs a number, because the count is
## program-dependent and differing figures in different places read as
## nobody having measured. Program: a one-file ``src/hello.nim`` whose whole
## body is ``echo "hello from s7"``, built with
## ``--tool-provisioning=path --daemon=off --no-runquota`` and a per-run
## ``--action-cache-root``; 41 observed writes in total. WITHOUT the
## declaration: *15 unaccounted paths, every one of them nimcache*, and the
## engine withheld the binary's payload (``CAS_BLOBS = 0``). So the flagship
## edge kind — the one the milestone's headline case is about — was
## correctly judged unsafe to restore, for a reason that is not actually a
## hazard.
##
## The declaration resolves it by being TRUE rather than by being
## convenient. Everything in the nimcache was produced by a previous run of
## this same action, from inputs that are themselves in the cache key; a
## rebuild regenerates it; nothing else in the graph reads it. That is what
## ``ignoredInputPrefixes`` already means — "machine-local derived state" —
## and it is the same declaration the interface-extract edge makes about its
## own scratch root. After it: 0 unaccounted paths, and a ``nim c``
## executable deleted from ``build/bin`` is restored from the CAS by the
## next ``repro build`` and runs.
##
## What this file pins is the narrowness of that claim. The declaration must
## name the nimcache the edge ACTUALLY uses and nothing above it: a prefix
## naming the output directory, or the project root, would exempt the
## binary's own neighbours from the gate and hand back exactly the
## incomplete restore the gate exists to refuse. The engine-side half —
## that an exempted prefix is honoured and that a sibling of the declared
## output still fails the gate — is
## ``libs/repro_build_engine/tests/test_s7_cached_output_restore_mode.nim``.

import std/[os, strutils, unittest]

import repro_project_dsl
# Aliased for the same reason as ``t_nim_c_cpu_flag``: the ``package nim:``
# block in that module emits a const named ``nim``, which a plain import
# would shadow with the module name.
import repro_dsl_stdlib/packages/nim as nim_module

const nimTool = nim_module.nim

proc ignoredPrefixes(act: BuildActionDef): seq[string] =
  act.dependencyPolicy.ignoredInputPrefixes

suite "S7 nim.c declares its nimcache as machine-local derived state":

  test "a cacheable edge declares the nimcache it was given":
    ## The explicit case first, because it is the one that must not be
    ## approximated: every ``cpu``-varying edge is handed its own nimcache
    ## precisely so two bitnesses cannot share one, and a declaration that
    ## fell back to the default-derived path would name a directory that
    ## edge never writes — leaving the one it does write unaccounted for.
    resetBuildActionRegistry()
    let cacheDir = "build" / "nimcache" / "s7_explicit"
    let act = nimTool.c(
      source = "src" / "app.nim",
      binary = "build" / "bin" / "s7_explicit.exe",
      nimcache = cacheDir)
    check ignoredPrefixes(act) == @[cacheDir]

  test "a cacheable edge with no explicit nimcache declares the default one":
    ## ``defaultNimcacheDir`` derives ``build/nimcache/<binary-basename>``,
    ## and that is what nim is told on the command line, so that is what has
    ## to be declared.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "app.nim",
      binary = "build" / "bin" / "s7_default")
    let expected = "build" / "nimcache" / "s7_default"
    check ignoredPrefixes(act) == @[expected]
    # And the argv agrees — the declaration is worthless if it names a
    # directory other than the one nim is actually handed.
    var sawNimcacheFlag = false
    for arg in act.call.arguments:
      if arg.alias == "--nimcache:":
        sawNimcacheFlag = true
        check arg.encodedValue == expected
    check sawNimcacheFlag

  test "the declaration does not reach above the nimcache":
    ## The over-broad direction, asserted rather than assumed. The engine
    ## exempts everything at or under an honoured prefix, so a prefix naming
    ## the output directory, the build directory or the project root would
    ## exempt the action's own undeclared products — which is the failure
    ## the restore gate exists to catch, reintroduced one layer up.
    ##
    ## *Scope of this assertion, stated because it is narrower than it
    ## looks.* It constrains the DERIVED default only. An explicit
    ## ``nimcache =`` is passed through unchanged (the case above pins that,
    ## and it has to be that way — a ``cpu``-varying edge handed its own
    ## directory must have THAT one declared), so nothing at this layer
    ## stops a recipe naming its own output directory. What stops it is one
    ## layer down and is the engine's rule rather than this wrapper's:
    ## ``honouredDerivedPrefixes`` drops a prefix that overlaps the action's
    ## declared product, so such a recipe loses the exemption and fails
    ## CLOSED — its edge is withheld from the CAS and re-runs — instead of
    ## silently exempting its binary's neighbours. Pinned in
    ## ``test_s7_cached_output_restore_mode.nim``, "a derived prefix
    ## disjoint from the product is still honoured".
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "app.nim",
      binary = "build" / "bin" / "s7_scope.exe")
    for prefix in ignoredPrefixes(act):
      check prefix.len > 0
      check prefix != "."
      check prefix != "build"
      check prefix != "build" / "bin"
      check not ("build" / "bin").startsWith(prefix & DirSep)
      check prefix.startsWith("build" / "nimcache")
    # The passthrough really is unconstrained here — asserted so the gap is
    # a tested fact rather than a claim in a comment, and so that anyone who
    # later constrains it at this layer has to come and delete this.
    resetBuildActionRegistry()
    let overreaching = nimTool.c(
      source = "src" / "app.nim",
      binary = "build" / "bin" / "s7_overreach.exe",
      nimcache = "build" / "bin")
    check ignoredPrefixes(overreaching) == @["build" / "bin"]

  test "a NON-cacheable edge is untouched":
    ## The non-cacheable branch keeps its make-depfile policy. It never
    ## reaches the action cache at all, so it has nothing to declare, and
    ## changing it would be scope this milestone did not ask for.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "app.nim",
      binary = "build" / "bin" / "s7_uncached.exe",
      cacheable = false)
    check act.dependencyPolicy.kind == bdpMakeDepfile
    check ignoredPrefixes(act).len == 0

  test "an explicit dependencyPolicy still wins":
    ## The wrapper only supplies a policy when the recipe did not. A recipe
    ## that states its own is making a stronger claim than the default, and
    ## silently appending to it would be the wrapper overruling an explicit
    ## declaration — the thing the codebase refuses to do everywhere else.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "app.nim",
      binary = "build" / "bin" / "s7_explicit_policy.exe",
      dependencyPolicy = automaticMonitorPolicy(@["scratch" / "mine"]))
    check act.dependencyPolicy.kind == bdpAutomaticMonitor
    check ignoredPrefixes(act) == @["scratch" / "mine"]

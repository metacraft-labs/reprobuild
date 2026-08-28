## Variant-conditioned `uses:` is over-approximated in ONE wave.
##
## Named-Lock-Files NLF-M5. Corpus case **NLF-GEN-6** (fetch half): "Metadata
## for all arms is fetched in one wave; no second wave is required."
##
## Design §5.6:
##
## > `uses:` may be **variant-conditioned** … which package a recipe depends
## > on can depend on a variant the solver has not yet chosen. Naively that
## > needs a fixpoint. It is resolved by **over-approximation**: every arm of a
## > variant-conditioned `uses:` is statically enumerable from the recipe
## > source, so the first wave fetches metadata for *all* arms and the solve
## > selects among them. **One wave, no iteration.**
##
## ## The property has three halves and all three are asserted
##
##   * **Over.** Metadata is fetched for arms the solve does not take. A plan
##     that fetched only the taken arm would have to resolve the variant
##     first, which is the fixpoint this must not be — and it would fetch
##     strictly less, so a test that only counted "did we fetch what we
##     needed" would pass it.
##   * **One wave.** The expansion closes after wave 1. An implementation that
##     converged after two waves would produce the SAME lock, so the lock
##     cannot witness this; only the wave count can.
##   * **The solve really selects.** Over-fetching is only interesting if the
##     arms are live. The `libarm` fixture below gives one package two
##     MUTUALLY EXCLUSIVE gated ranges, so a solve in which both fired would be
##     UNSAT — satisfiability is itself the evidence that exactly one arm
##     activated, and the chosen version says which.
##
## ## What this file deliberately does NOT assert
##
## That a dormant arm's package is absent from the lock. It is not: a
## variant-conditioned dependency gates the RANGE CONSTRAINT, not the
## package's presence in the solved graph (`repro_solver/version_encoder`'s
## header, item 5, and `t_version_encoder_conditional_deps.nim`'s "the
## constraint never fired, so the solver may pick any version"). Asserting
## absence would be asserting something false about the encoder, and asserting
## a particular free choice would be asserting something the encoder does not
## promise — it has no version-preference objective.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real loopback TCP + real HTTP/1.1 + the real in-process `http_pool` client
## for the fetch; the real `runBuild`; a real clingo solve for the arm
## selection. See `loopback_metadata_server`'s header. The two synthetic
## expanders in the last suite are not doubles of anything under test — they
## are INPUTS to `expandGraphInWaves`, which is the code under test; there is
## no production rule generator that loops, and manufacturing one is the only
## way to observe the detector.

import std/[algorithm, os, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_lock
import repro_lock_gen
import repro_solver

import ./loopback_metadata_server

const
  App = "app"
  TlsVariant = "tls"
  LibArm = "libarm"
    ## Depended on by BOTH arms, under mutually exclusive ranges. The arm
    ## selector.
  LibSecure = "libsecure"   ## reached only from the `tls=true` arm
  LibPlain = "libplain"     ## reached only from the `tls=false` arm
  ArmHigh = "3.0.0"         ## the only `libarm` satisfying `>=3.0`
  ArmLow = "1.1.0"          ## the only `libarm` satisfying `<2.0`
  SideVersion = "2.2.0"

proc request(server: MetadataServer; workDir: string;
             tlsDefault: string): LockGenerationRequest =
  ## The recipe. Neither arm's package is DECLARED with a candidate universe:
  ## every universe comes from the registry, so the fetch is load-bearing
  ## rather than a decoration on a solve that could have run without it.
  LockGenerationRequest(
    variants: @[newBoolVariant(TlsVariant,
      @[contribution(vpDefault, tlsDefault)])],
    packages: @[
      newPackage(App, @["1.0.0"], @[
        newConditionalDependency(LibArm, ">=3.0", TlsVariant, "true"),
        newConditionalDependency(LibArm, "<2.0", TlsVariant, "false"),
        newConditionalDependency(LibSecure, ">=1.0", TlsVariant, "true"),
        newConditionalDependency(LibPlain, ">=1.0", TlsVariant, "false")])],
    inputsText: "nlf-gen-6 fixture",
    platform: currentPlatformId(),
    strategy: lsDefault,
    endpoints: @[server.endpoint()],
    workDir: workDir,
    entryPoint: lgeLockSolve)

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-nlf-gen6-", "")
  let server {.inject.} = startMetadataServer(scratch / "registry")
  server.publish(App, ["1.0.0"])
  server.publish(LibArm, [ArmLow, ArmHigh])
  server.publish(LibSecure, [SideVersion])
  server.publish(LibPlain, [SideVersion])
  try:
    body
  finally:
    server.stop()
    removeDir(scratch)

proc entryFor(plan: seq[MetadataFetchPlanEntry];
              name: string): MetadataFetchPlanEntry =
  for e in plan:
    if e.packageName == name: return e
  raise newException(ValueError, "no fetch planned for " & name &
    " (planned: " & $plan.len & " entries)")

proc metadataObject(scratch, workDir, name: string): string =
  scratch / workDir / "metadata" / (name & ".versions")

suite "NLF-GEN-6 the plan enumerates every arm":

  test "one package reached from two arms is planned once, with both arms":
    withScenario:
      let plan = request(server, scratch / "plan", "true").fetchPlan()
      let arm = plan.entryFor(LibArm)
      # One retrieved object, both arms recorded against it. This is the
      # over-approximation in its smallest form: the entry exists before
      # anything knows which arm will be taken.
      check arm.arms == @[TlsVariant & "=false", TlsVariant & "=true"]
      check arm.url.endsWith("/" & LibArm & ".versions")

  test "a package reached from only one arm is still planned":
    withScenario:
      let plan = request(server, scratch / "plan", "true").fetchPlan()
      check plan.entryFor(LibSecure).arms == @[TlsVariant & "=true"]
      check plan.entryFor(LibPlain).arms == @[TlsVariant & "=false"]
      # `app` is the root declaration, so its arm is the unconditioned one.
      check plan.entryFor(App).arms == @["*"]
      check plan.len == 4

  test "the plan does not depend on which arm the variant would take":
    # The fixpoint-detector. If the plan narrowed to the arm the default would
    # select, flipping the default would change the plan. It must not: the
    # whole point is that the plan is buildable before the variant has a value.
    withScenario:
      let whenTrue = request(server, scratch / "p-true", "true").fetchPlan()
      let whenFalse = request(server, scratch / "p-false", "false").fetchPlan()
      var namesTrue, namesFalse: seq[string] = @[]
      for e in whenTrue: namesTrue.add(e.packageName)
      for e in whenFalse: namesFalse.add(e.packageName)
      check namesTrue == namesFalse
      check LibSecure in namesTrue
      check LibPlain in namesTrue
      check whenTrue.entryFor(LibArm).arms == whenFalse.entryFor(LibArm).arms

suite "NLF-GEN-6 one wave, and it is genuinely over-approximated":

  test "every arm's metadata is fetched in a single wave":
    withScenario:
      let generated = runLockSolve(
        request(server, scratch / "gen", "true"), "")
      # One wave. Not "converged after two".
      check generated.fetchWaves.len == 1
      let wave = generated.fetchWaves[0]
      check wave.len == 4
      var fetched: seq[string] = @[]
      for id in wave:
        fetched.add(id.rsplit('/', maxsplit = 1)[^1])
      fetched.sort()
      check fetched == @[App, LibArm, LibPlain, LibSecure]
      check generated.fetchAttempts == 4
      check server.requestsServed() == 4

  test "the solve takes exactly one arm, out of metadata fetched for all":
    # Satisfiability is the evidence that exactly one arm fired: `>=3.0` and
    # `<2.0` over the same package cannot both hold, so a solve in which the
    # gate did nothing would be UNSAT rather than wrong.
    withScenario:
      let generated = runLockSolve(
        request(server, scratch / "gen", "true"), "")
      let sol = lockToSolution(parseSolvedGraphLock(generated.lockDocument))
      check sol.variants[TlsVariant] == "true"
      check sol.packages[LibArm] == ArmHigh

      # And the arm that was NOT taken had its metadata retrieved anyway —
      # over the wire, written down, with the evidence §5.6 asks for: the
      # digest of what was ACTUALLY retrieved, computed after the fact.
      let plainObject = metadataObject(scratch, "gen", LibPlain)
      check fileExists(plainObject)
      check parseVersionList(readFile(plainObject)) == @[SideVersion]
      check fileExists(plainObject & ".evidence")
      let evidence = readFile(plainObject & ".evidence")
      check evidence.contains("integrity=blake3:")
      check evidence.contains("url=http://127.0.0.1:")

  test "flipping the variant takes the other arm from the same one wave":
    # The control. Without it, "libarm resolved to 3.0.0" is also satisfied by
    # an implementation in which the gate does nothing and 3.0.0 simply wins.
    withScenario:
      let generated = runLockSolve(
        request(server, scratch / "gen-false", "false"), "")
      check generated.fetchWaves.len == 1
      check generated.fetchAttempts == 4
      let sol = lockToSolution(parseSolvedGraphLock(generated.lockDocument))
      check sol.variants[TlsVariant] == "false"
      check sol.packages[LibArm] == ArmLow

      let secureObject = metadataObject(scratch, "gen-false", LibSecure)
      check fileExists(secureObject)
      check parseVersionList(readFile(secureObject)) == @[SideVersion]

suite "NLF-GEN-6 the wave driver has cycle detection and a bound":
  ## `Package-Model.md`: "expand the graph in explicit waves until a closed
  ## frontier is reached, **with cycle detection and a bounded iteration
  ## policy**." A driver missing either would still close the generation
  ## expansion above in one wave, so these are asserted directly.

  let identity = emptySolvedGraphIdentity(currentPlatformId())

  proc edge(id: string): BuildAction =
    builtinAction(bakStamp, id, governingLockIdentity = identity,
      outputs = ["out/" & id])

  test "an expansion that closes reports the frontier closed":
    let expansion = expandGraphInWaves(@[edge("seed")],
      proc(previousWave: seq[BuildAction]): seq[BuildAction] = @[])
    check expansion.closed
    check expansion.waves.len == 1

  test "a generator that re-emits an earlier action is a detected cycle":
    var raised = false
    var message = ""
    try:
      discard expandGraphInWaves(@[edge("seed")],
        proc(previousWave: seq[BuildAction]): seq[BuildAction] =
          @[edge("seed")])
    except WaveExpansionCycle as err:
      raised = true
      message = err.msg
    check raised
    check message.contains("expansion cycle")
    check message.contains("seed")

  test "a productive but non-terminating generator hits the bound":
    # The case cycle detection cannot see: every wave is a NEW action, so
    # nothing ever repeats. Without the bound this is an infinite loop that
    # presents as a hang.
    var counter = 0
    var raised = false
    var message = ""
    try:
      discard expandGraphInWaves(@[edge("seed")],
        proc(previousWave: seq[BuildAction]): seq[BuildAction] =
          inc counter
          @[edge("generated-" & $counter)],
        maxWaves = 4)
    except WaveExpansionBoundExceeded as err:
      raised = true
      message = err.msg
    check raised
    check message.contains("closed frontier within 4 wave(s)")
    check message.contains("generated-4")

  test "the generation expansion runs under a bound of two":
    # Tight on purpose: §5.6's expansion is one wave by construction, so one
    # wave of slack turns "somebody made the fetch a fixpoint" into a loud
    # failure rather than a quiet extra round-trip.
    check MaxGenerationWaves == 2

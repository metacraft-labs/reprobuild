## DA-6 — a tool-package capture-breadth declaration cannot drop evidence a
## reprobuild consumer reads.
##
## # What this file is for
##
## DA-6 moves one decision outwards: how much of io-mon's event stream a
## monitored action asks for is now declared by the TOOL PACKAGE
## (`packages/nim.nim`, `packages/gcc.nim`, …) rather than fixed at
## `FullInterest` in the engine. Moving a decision outwards means a new class of
## mistake becomes expressible, and DA-5 named that class: a narrowing that
## removes evidence some consumer needs produces a capture that grades
## `mcComplete` while missing it — a FALSE CACHE HIT, and the cardinal sin of
## this whole campaign.
##
## So the assertions here are not "the declaration reads back". They are:
##
##   1. EVERY declaration the vocabulary admits still asks for every category a
##      reprobuild consumer reads, and the consumer is NAMED when it does not.
##   2. The two halves of the vocabulary are pinned to distinct sets, so
##      `mcbOmitAmbientReads` cannot quietly become a synonym for
##      `mcbFullCapture` and leave every other assertion here vacuous.
##   3. `ReprobuildConsumedInterest` agrees with `interestConsumer`, in BOTH
##      directions, so the set cannot be narrowed without deleting the name of
##      the code that reads the category.
##   4. THE FALSE-COMPLETE DIRECTION: for every declaration, and for every
##      consumed category, a capture STAMPED as having dropped that category is
##      REFUSED. This is the one that fails if a declaration is stretched into
##      trusting narrowed evidence, and it is asked through the real
##      `monitorScopeRefusal` rather than by comparing sets, because the refusal
##      is what actually withholds the cache publish.
##   5. The ASK side and the REQUIRE side agree: an action that declares a
##      narrowing must TRUST a capture that observed exactly what it asked for
##      (otherwise a declaration would refuse its own captures, and the edge
##      would never publish), while an action that declares full capture must
##      REFUSE that same narrowed capture. That pair is what makes the
##      declaration load-bearing in both directions; each half alone is
##      satisfiable by an engine that ignores the declaration entirely.
##
## # Mocks
##
## NONE, and there is nothing here that could be mocked usefully.
## `declaredMonitorInterest`, `interestConsumer`, `ReprobuildConsumedInterest`,
## `monitorInterest` and `monitorScopeRefusal` are the production symbols.
## The only constructed values are `BuildAction`s carrying a
## `DependencyGatheringPolicy` (a plain data object, built the way the lowering
## builds it) and depfile BYTES — real `mrBackendProfile` record details in
## io-mon's own stamp format, decoded by io-mon's own `depFileFromRecords`, so
## the interest stamps are read exactly as a capture's would be. The per-tool
## half of DA-6, which reads declarations off REAL registered edges produced by
## the real package macros, is
## `tests/integration/t_da6_tool_capture_breadth_declarations.nim`.
##
## # The exhaustive loops are the point
##
## Every loop below iterates `MonitorCaptureBreadth` and `EventCategory` rather
## than naming members, so a category added to io-mon or a word added to the
## vocabulary is covered here the day it is added — the same construction
## io-mon's own DA-5 tests use, for the same reason: this axis's failure
## direction is ACCEPT, and a hand-written list of cases is a list that grows a
## gap silently.

import std/[strutils, unittest]

import repro_build_engine
import repro_core
import io_mon

proc policyWith(breadth: MonitorCaptureBreadth): DependencyGatheringPolicy =
  ## An automatic-monitor policy carrying exactly `breadth` — the shape
  ## `loweredDependencyPolicy` produces for a monitored edge.
  result = automaticMonitorGatheringPolicy()
  result.captureBreadth = breadth

proc actionWith(breadth: MonitorCaptureBreadth): BuildAction =
  ## Built through the production `action()` constructor rather than by object
  ## literal, so the policy travels the route a real edge's does (`action()`
  ## rewrites `dependencyPolicy` in one case — a legacy `depfile` — and this
  ## check would be worth nothing if it bypassed that).
  action("da6-" & $breadth, ["/bin/true"],
    dependencyPolicy = policyWith(breadth),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc captureStamped(tokens: string): MonitorDepFile =
  ## A depfile carrying ONE `mrBackendProfile` record whose detail states
  ## `interest=<tokens>` — io-mon's own stamp channel, decoded by io-mon's own
  ## reader, so this is what a real capture's stamp looks like on the way in.
  let profile = MonitorRecord(
    kind: mrBackendProfile,
    path: "backend",
    detail: "backend=test;interest=" & tokens & ";evidenceComplete=true")
  depFileFromRecords(@[profile])

suite "DA-6 no declaration can drop a category a consumer reads":

  test "every declaration asks for every consumed category, consumer named":
    ## THE CHOKEPOINT, asserted at run time as well as in the `static:` block
    ## beside `declaredMonitorInterest`. The compile-time copy is what actually
    ## prevents the mistake; this one exists so that a reader who breaks it sees
    ## WHICH consumer they broke, by name, in the failure output — a compile
    ## error in a `static:` block is a wall of text about a `doAssert`.
    for breadth in MonitorCaptureBreadth:
      let asked = declaredMonitorInterest(breadth)
      for category in ReprobuildConsumedInterest:
        if category notin asked:
          echo "DECLARATION `", breadth, "` DROPS `", interestToken(category),
            "`, whose records are read by ", interestConsumer(category), ".",
            "\n  A tool package cannot be allowed to say this: the capture ",
            "comes back without the evidence and still grades mcComplete, ",
            "which is a false cache hit — DA-5's cardinal sin."
        check category in asked

  test "the two words of the vocabulary are not synonyms":
    ## WITHOUT THIS EVERY OTHER CASE HERE IS SATISFIABLE BY A VOCABULARY THAT
    ## MEANS NOTHING. Map both words to `FullInterest` and the chokepoint above
    ## holds trivially, the refusal cases below hold trivially, and DA-6 asserts
    ## nothing at all. So the narrowing is pinned to the EXACT set DA-5 proved
    ## safe, and full capture to the whole enum.
    check declaredMonitorInterest(mcbFullCapture) == FullInterest
    check declaredMonitorInterest(mcbOmitAmbientReads) ==
      FullInterest - {ecAmbientReads}
    check declaredMonitorInterest(mcbOmitAmbientReads) !=
      declaredMonitorInterest(mcbFullCapture)

  test "the consumed set and the consumer table agree in both directions":
    ## `ReprobuildConsumedInterest` is DERIVED from `interestConsumer`, so this
    ## looks tautological. It is not, and the direction that is not tautological
    ## is the second one: it pins the DERIVATION's meaning. If someone replaces
    ## the derived constant with a hand-written literal — the one construction
    ## on this axis whose failure direction is ACCEPT — this case is what
    ## notices, because a literal that drops a category leaves that category's
    ## consumer NAME behind.
    for category in FullInterest:
      let named = interestConsumer(category).len > 0
      if named != (category in ReprobuildConsumedInterest):
        echo "`", interestToken(category), "` has consumer `",
          interestConsumer(category), "` but is ",
          (if category in ReprobuildConsumedInterest: "IN" else: "NOT IN"),
          " ReprobuildConsumedInterest. The set must be exactly the categories ",
          "some named consumer reads; a category in the set with no consumer ",
          "costs records for nothing, and a category with a consumer outside ",
          "the set is droppable evidence somebody depends on."
      check named == (category in ReprobuildConsumedInterest)

  test "the consumed set is still DA-5's safe subset":
    ## DA-5 proved over all 256 interest sets that `FullInterest -
    ## {ecAmbientReads}` is the ONLY safe proper subset. This is the tripwire
    ## for that result going stale in either direction: a consumer appearing for
    ## the ambient reads retires the only narrowing this engine has, and a
    ## consumer disappearing from any other category opens a narrowing that has
    ## to be argued rather than noticed.
    check ReprobuildConsumedInterest == FullInterest - {ecAmbientReads}
    check interestConsumer(ecAmbientReads).len == 0
    check interestConsumer(ecEnvReads).contains("cacheEnvInputs")
    check interestConsumer(ecEntropy).contains("applyEntropyBlessingPolicy")

suite "DA-6 the false-complete direction":

  test "no declaration trusts a capture that dropped a consumed category":
    ## THE CARDINAL-SIN CASE, and the reason it is asked through
    ## `monitorScopeRefusal` rather than by comparing two sets: the refusal
    ## sentence is what withholds the action-cache publish, so the property that
    ## matters is "the real consumer check says no", not "the sets look wrong".
    ##
    ## For every declaration a tool package can make, and every category some
    ## reprobuild consumer reads, a capture that STATES it dropped that
    ## category must be refused. `mcbOmitAmbientReads` is in the loop too and it
    ## is the interesting arm: a declaration that narrowed once must not thereby
    ## have become tolerant of narrowings it did not ask for.
    for breadth in MonitorCaptureBreadth:
      let required = MonitorEvidenceRequirement(
        interest: declaredMonitorInterest(breadth), evidenceScope: esFull)
      for dropped in ReprobuildConsumedInterest:
        let narrowed = FullInterest - {dropped}
        let dep = captureStamped(interestToTokens(narrowed))
        let refusal = monitorScopeRefusal(dep, required)
        if refusal.len == 0:
          echo "an action declaring `", breadth, "` ACCEPTED a capture ",
            "stamped `interest=", interestToTokens(narrowed), "`, which ",
            "dropped `", interestToken(dropped), "` — records read by ",
            interestConsumer(dropped), ". Accepting it publishes an action ",
            "cache entry from evidence that is missing the thing the key or ",
            "the gate needed: a false mcComplete."
        check refusal.len > 0

  test "a declared narrowing still trusts exactly what it asked for":
    ## THE ANTI-REFUSE-EVERYTHING CONTROL, and it is load-bearing rather than
    ## decorative. "Refuse every capture" satisfies the case above perfectly and
    ## would stop every monitored edge from ever publishing. The ask side and
    ## the require side are derived from the SAME answer
    ## (`monitorEvidenceRequirement` reads `monitorInterest`), so a capture that
    ## observed exactly what the declaration asked for has to be trusted.
    for breadth in MonitorCaptureBreadth:
      let asked = declaredMonitorInterest(breadth)
      let required = MonitorEvidenceRequirement(
        interest: asked, evidenceScope: esFull)
      let dep = captureStamped(interestToTokens(asked))
      let refusal = monitorScopeRefusal(dep, required)
      if refusal.len > 0:
        echo "an action declaring `", breadth, "` REFUSED a capture that ",
          "observed exactly what it asked for: ", refusal,
          "\n  The two sides are derived from one answer; if they can ",
          "disagree, a declared narrowing is an edge that never publishes."
      check refusal.len == 0

  test "full capture REFUSES the narrowed capture the narrowing accepts":
    ## THE PAIR THAT MAKES THE DECLARATION LOAD-BEARING. The two cases above
    ## are each satisfiable by an engine that ignores the declaration and always
    ## demands `FullInterest`, or by one that always demands the narrow set. The
    ## discrimination is that ONE capture — stamped with the narrow set — must
    ## be trusted by the narrow declaration and refused by the full one.
    let narrowStamp = interestToTokens(declaredMonitorInterest(mcbOmitAmbientReads))
    let dep = captureStamped(narrowStamp)
    let underNarrow = monitorScopeRefusal(dep, MonitorEvidenceRequirement(
      interest: declaredMonitorInterest(mcbOmitAmbientReads),
      evidenceScope: esFull))
    let underFull = monitorScopeRefusal(dep, MonitorEvidenceRequirement(
      interest: declaredMonitorInterest(mcbFullCapture),
      evidenceScope: esFull))
    check underNarrow.len == 0
    if underFull.len == 0:
      echo "a FULL-CAPTURE declaration accepted a capture stamped `interest=",
        narrowStamp, "`. The two declarations must be distinguishable by some ",
        "capture, or the vocabulary is decoration and every tool package's ",
        "reasoning is unread."
    check underFull.len > 0

suite "DA-6 monitorInterest reads the declaration off the action":

  test "the action's declaration is what monitorInterest answers":
    ## The engine half of the wiring, and the reason `monitorInterest` is
    ## exported. Without this case the whole vocabulary could be correct and
    ## completely unconsulted: `monitorInterest` returning `FullInterest`
    ## unconditionally — its pre-DA-6 body — satisfies every assertion above
    ## except this one.
    for breadth in MonitorCaptureBreadth:
      let answered = monitorInterest(actionWith(breadth))
      if answered != declaredMonitorInterest(breadth):
        echo "an action declaring `", breadth, "` was asked for `",
          interestToTokens(answered), "`, not the declared `",
          interestToTokens(declaredMonitorInterest(breadth)), "`. ",
          "monitorInterest is ignoring the tool package."
      check answered == declaredMonitorInterest(breadth)

  test "a default-constructed policy asks for everything":
    ## THE ZERO VALUE, and it has to be the WIDEST answer rather than the
    ## narrowest — the same principle `effectiveRequiredInterest` rests on. A
    ## `BuildAction` reaches this proc from a `newSeq`, a missing named
    ## argument, a direct-engine-API caller and most of this suite; every one of
    ## those must get full capture, because the cost of being wrong that way is
    ## records nobody reads and the cost of the other way is a narrowed capture
    ## nobody asked for.
    check DependencyGatheringPolicy().captureBreadth == mcbFullCapture
    let zeroPolicyAction = action("da6-zero-policy", ["/bin/true"],
      dependencyPolicy = DependencyGatheringPolicy(kind: dgAutomaticMonitor),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check monitorInterest(zeroPolicyAction) == FullInterest

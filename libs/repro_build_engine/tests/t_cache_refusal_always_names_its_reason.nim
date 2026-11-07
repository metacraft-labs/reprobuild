## A withheld action-cache publish cannot be made without naming the class
## that withheld it.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED. It
## exercises ``repro_build_engine/cache_refusal`` directly: a value type with
## no I/O, no clock and no collaborator, so there is nothing to stand in for.
##
## WHAT IS BEING PINNED. The engine's ``EvidenceCollection`` used to carry the
## refusal as two fields — a ``disableCacheHits`` flag and a
## ``cacheIneligibilityReasons`` set — that every refusing site had to write
## together by convention. ``gradeKeyedInputSet`` set the flag and omitted the
## class, and because ``determinismProbeAdmits`` compares that set EXACTLY
## against ``{cirUnblessedEntropy}``, an action refused for entropy AND for an
## empty keyed input set presented as "entropy alone" and the probe published
## it (reprobuild-pm issue
## ``2026-10-04-nothing-structurally-pairs-a-publish-refusal-with-its-reason``;
## the end-to-end case is in ``t_zero_evidence_edge_is_not_cacheable``).
##
## The fix makes the unpaired state unrepresentable: ``CacheRefusal`` has ONE
## private field, the reason set; "refused" is derived from it; and the only
## writer, ``refuse``, takes the reason as an argument. The cases below pin
## both halves — the behaviour of the accessors, and, at compile time, that
## code outside the module (as the engine is) has no other way in.
##
## WHY THE COMPILE-TIME CASES ARE NOT VACUOUS. ``not compiles(expr)`` also
## passes when ``expr`` is malformed for a reason unrelated to privacy — a
## typo, a wrong literal — and would then pin nothing. So every refused shape
## is ALSO checked to compile against ``OpenRefusal`` below, a lookalike with
## the same field names and types made public. The only difference between the
## two checks is the restriction under test, so a ``not compiles`` here fails
## to compile for exactly that reason. A positive control on ``CacheRefusal``
## itself (``refuse`` compiles) shows the value is in scope and usable.
##
## MUTATION-CHECKED (2026-10-16, by editing ``cache_refusal.nim`` and
## restoring it): against the tree before this change the module does not
## exist and this file does not compile; with the field exported
## (``reasons*``) the assignment, ``incl`` and construction checks of the
## last case fail; with ``refused`` turned into a public ``bool`` field the
## settable-flag check fails, and so do the two cases that expect
## ``refuse`` to make the value refused.

import std/unittest

import repro_build_engine/cache_refusal

type
  OpenRefusal = object
    ## The positive control for the ``not compiles`` cases: ``CacheRefusal``'s
    ## shape with every field public, plus the flag the old design carried.
    ## Each bypass that must NOT compile against ``CacheRefusal`` is shown to
    ## compile against this, so its refusal there is the privacy and nothing
    ## else.
    reasons*: set[CacheIneligibilityReason]
    refused*: bool

suite "CacheRefusal: a refusal is never without its reason":
  test "the zero value is not refused and names no reason":
    ## The default an ``EvidenceCollection`` starts with: Nim zero-initialises
    ## every ``var``, ``result`` and object field, and a fresh action must be
    ## publishable until some gate decides otherwise.
    let r = default(CacheRefusal)
    check not r.refused
    check r.reasons == {}
    var v: CacheRefusal
    check not v.refused
    check v.reasons.card == 0

  test "refusing names exactly the reason given":
    var r: CacheRefusal
    r.refuse(cirEmptyKeyedInputSet)
    check r.refused
    check r.reasons == {cirEmptyKeyedInputSet}
    # Idempotent per reason: a second refusal for the same class adds nothing.
    r.refuse(cirEmptyKeyedInputSet)
    check r.reasons == {cirEmptyKeyedInputSet}

  test "refusals accumulate, and their reasons iterate in ordinal order":
    ## Accumulation is what ``determinismProbeAdmits`` depends on: entropy plus
    ## any other class must NOT equal ``{cirUnblessedEntropy}``. Ordinal order
    ## is what ``traceCacheIneligibility`` joins the trace text in, which the
    ## engine suites pin byte-for-byte, so the order of the CALLS must not leak
    ## into it.
    var r: CacheRefusal
    r.refuse(cirEmptyKeyedInputSet)
    r.refuse(cirUnblessedEntropy)
    check r.refused
    check r.reasons == {cirUnblessedEntropy, cirEmptyKeyedInputSet}
    check r.reasons != {cirUnblessedEntropy}
    var order: seq[CacheIneligibilityReason] = @[]
    for reason in r.reasons:
      order.add(reason)
    check order == @[cirUnblessedEntropy, cirEmptyKeyedInputSet]
    var text: seq[string] = @[]
    for reason in r.reasons:
      text.add($reason)
    check text == @["unblessed-entropy", "empty-keyed-input-set"]

  # The compile-time cases bind each ``compiles`` result to a ``let`` and
  # check the name, never ``check compiles(...)`` directly: ``unittest``'s
  # ``check`` rewrites a call's arguments into temporaries so it can print
  # them on failure, which would hoist the very expression ``compiles`` is
  # meant to keep unevaluated out of it.
  #
  # Assignments go in a ``compiles do:`` block, never ``compiles(a.b = c)``.
  # Inside a call's parentheses ``a.b = c`` parses as a NAMED ARGUMENT, so
  # that spelling never compiles whatever the field's visibility — the
  # controls below caught exactly this on the first run, when both
  # assignment checks were vacuously passing their ``not compiles`` twins.

  test "the controls: each bypass shape compiles when the field is public":
    ## If any of these stopped compiling, the matching case below would be
    ## passing for the wrong reason.
    var o: OpenRefusal
    let assignSet = compiles do:
      o.reasons = {cirMonitorLoss}
    let inclIntoSet = compiles(o.reasons.incl(cirMonitorLoss))
    let constructWithSet = compiles(OpenRefusal(reasons: {cirMonitorLoss}))
    let setRefusedFlag = compiles do:
      o.refused = true
    check assignSet
    check inclIntoSet
    check constructWithSet
    check setRefusedFlag
    # And the sanctioned surface of ``CacheRefusal`` is in scope and usable,
    # so the cases below are not failing on an unresolved name.
    var r: CacheRefusal
    let refuseWithReason = compiles(r.refuse(cirMonitorLoss))
    let readReasons = compiles(r.reasons)
    let readRefused = compiles(r.refused)
    check refuseWithReason
    check readReasons
    check readRefused
    # ``compiles`` evaluates nothing, so neither value was touched.
    check o.reasons == {}
    check not r.refused

  test "outside the module, there is no way to refuse without a reason":
    var r: CacheRefusal
    # Assigning the set wholesale — including the empty set beside a flag,
    # which is the state the old design could reach.
    let assignSet = compiles do:
      r.reasons = {cirMonitorLoss}
    # Adding to the set without going through ``refuse``. ``reasons`` returns
    # a copy, so there is nothing addressable to ``incl`` into.
    let inclIntoSet = compiles(r.reasons.incl(cirMonitorLoss))
    # Constructing a value with a chosen set.
    let constructWithSet = compiles(CacheRefusal(reasons: {cirMonitorLoss}))
    # Setting "refused" directly: it is derived, so there is nothing to set.
    let setRefusedFlag = compiles do:
      r.refused = true
    check not assignSet
    check not inclIntoSet
    check not constructWithSet
    check not setRefusedFlag
    check not r.refused

## DSL-port M9.E acceptance — ``validate:`` predicate closures.
##
## Pins the M9.E ``validate:`` directive contract. NDEM1 declares
## "the active-at-boot DE must be in the declared desktopKind list":
##
##   validate:
##     proc(): bool =
##       readConfigurable[DesktopKind]("valPkg", "activeAtBoot", dkSway) in
##         readConfigurable[seq[DesktopKind]]("valPkg", "desktopKind", @[])
##
## The macro splices the lambda verbatim into a
## ``registerValidateExpr`` call; ``evaluateValidates`` calls each
## registered closure and raises ``EConfigViolation`` on first false.
##
## Coverage:
##
##   * ``registeredValidates`` returns one row per declared ``validate:``
##     block with the body's repr captured into ``exprRepr``.
##   * Passing predicate: ``evaluateValidates`` does NOT raise on the
##     default configurable values.
##   * Failing predicate: overriding ``activeAtBoot`` to a value NOT
##     in ``desktopKind`` causes ``evaluateValidates`` to raise
##     ``EConfigViolation``.
##
## The ``readConfigurable`` calls inside the lambda use the M9.D
## fallback overload so a missing-key probe degrades gracefully —
## matches the form NDE recipes will adopt.

import std/[unittest]

import repro_project_dsl

type
  DesktopKindV* = enum
    dkSway
    dkGnome
    dkPlasma

package valPkg:
  config:
    activeAtBoot: DesktopKindV = dkSway
    desktopKind: seq[DesktopKindV] = @[dkSway, dkGnome]
  validate:
    proc(): bool =
      readConfigurable[DesktopKindV](
        "valPkg.activeAtBoot", dkSway) in
        readConfigurable[DesktopKindV](
          "valPkg.desktopKind", newSeq[DesktopKindV]())

suite "DSL-port M9.E — validate: predicate closures":

  test "validate predicate registers exactly once":
    let preds = registeredValidates("valPkg")
    check preds.len == 1
    # The exprRepr captures the body source — a non-empty diagnostic
    # surface that the runtime embeds in the violation message.
    check preds[0].exprRepr.len > 0
    check preds[0].packageName == "valPkg"

  test "passing predicate does NOT raise":
    # Reset both keys so the registered defaults are observed:
    # activeAtBoot = dkSway, desktopKind = @[dkSway, dkGnome].
    # dkSway in @[dkSway, dkGnome] → true → no raise.
    resetConfigurable("valPkg.activeAtBoot")
    resetConfigurable("valPkg.desktopKind")
    # No exception should escape — exercise via a try/except that fails
    # the test on a thrown EConfigViolation.
    var raised = false
    try:
      evaluateValidates("valPkg")
    except EConfigViolation:
      raised = true
    check raised == false

  test "failing predicate raises EConfigViolation":
    # Override activeAtBoot to dkPlasma — NOT in @[dkSway, dkGnome].
    setConfigurable[DesktopKindV](
      "valPkg.activeAtBoot", dkPlasma)
    # The override is observable to the closure via readConfigurable.
    check readConfigurable[DesktopKindV](
      "valPkg.activeAtBoot", dkSway) == dkPlasma
    # And ``desktopKind`` still reads back as the registered default.
    let dk = readConfigurable[DesktopKindV](
      "valPkg.desktopKind", newSeq[DesktopKindV]())
    check dk == @[dkSway, dkGnome]
    # Now the predicate MUST fire: dkPlasma notin @[dkSway, dkGnome].
    expect EConfigViolation:
      evaluateValidates("valPkg")
    # Restore the default so test ordering is robust.
    resetConfigurable("valPkg.activeAtBoot")

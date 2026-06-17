## DSL-port M9.E acceptance — ``variant <configField>:`` ``uses:`` arms.
##
## Pins the M9.E ``variant:`` directive contract. NDEM1 (reproos-desktop)
## declares "if desktopKind contains dkSway, depend on the sway package;
## if dkGnome, depend on gnome; ..." — the ``variant:`` block lowers
## each ``\`case\` <enumValue>:`` arm into a registered
## ``DslVariantArm`` row, and ``activeVariantArms`` filters to the rows
## the current configurable value selects.
##
## Coverage:
##
##   * ``registeredVariants`` returns one row per declared arm in
##     insertion order, with the ``armValue`` / ``armOrd`` / ``uses
##     Clauses`` captured.
##   * The arms' ``armValue`` strings byte-match the source-level enum
##     literal spellings ($value); ``armOrd`` matches ``ord(value)``.
##   * Each arm carries the per-arm ``uses "..."`` clause payload
##     verbatim.
##   * ``activeVariantArms`` walks the registered seq, reads the
##     configurable's current value via ``inspectConfigurable``, and
##     returns the matching arms — exercising both default and
##     overridden states.

import std/[unittest]

import repro_project_dsl

type
  DesktopKind* = enum
    dkSway
    dkGnome
    dkPlasma

package vPkg:
  config:
    desktopKind: seq[DesktopKind] = @[dkSway]
  variant desktopKind:
    `case` dkSway:
      uses "sway >=0.1.0"
    `case` dkGnome:
      uses "gnome >=0.1.0"
    `case` dkPlasma:
      uses "plasma >=0.1.0"

suite "DSL-port M9.E — variant: uses arms":

  test "three arms register in source-declaration order":
    # Reset the configurable cell so the default is observable; the
    # arms themselves are not part of the override surface (they are
    # registered once at module-init time).
    resetConfigurable("vPkg.desktopKind")
    let arms = registeredVariants("vPkg")
    check arms.len == 3
    # Per-arm spellings + ordinals — by source order.
    check arms[0].armValue == "dkSway"
    check arms[0].armOrd == ord(dkSway)
    check arms[0].usesClauses == @["sway >=0.1.0"]
    check arms[1].armValue == "dkGnome"
    check arms[1].armOrd == ord(dkGnome)
    check arms[1].usesClauses == @["gnome >=0.1.0"]
    check arms[2].armValue == "dkPlasma"
    check arms[2].armOrd == ord(dkPlasma)
    check arms[2].usesClauses == @["plasma >=0.1.0"]
    # NDE-I close-out: ``armValueRepr`` captures ``$value`` so the
    # ``activeVariantArms`` matcher can dual-key on ident vs. $value
    # under explicit-string-value enums. For this fixture's bare-value
    # ``DesktopKind`` (no ``= "..."``), ``$dkSway == "dkSway"`` —
    # ``armValueRepr`` coincides with ``armValue``.
    check arms[0].armValueRepr == "dkSway"
    check arms[1].armValueRepr == "dkGnome"
    check arms[2].armValueRepr == "dkPlasma"
    # All three arms key off the same outer ``variant desktopKind:``
    # head; the captured config-field name round-trips.
    check arms[0].variantConfigField == "desktopKind"
    check arms[1].variantConfigField == "desktopKind"
    check arms[2].variantConfigField == "desktopKind"

  test "activeVariantArms tracks the current configurable value":
    # Default configurable value is @[dkSway]; only the dkSway arm
    # fires.
    resetConfigurable("vPkg.desktopKind")
    let activeDefault = activeVariantArms("vPkg", "desktopKind")
    check activeDefault.len == 1
    check activeDefault[0].armValue == "dkSway"
    check activeDefault[0].usesClauses == @["sway >=0.1.0"]
    # Override to @[dkSway, dkGnome] — both arms fire.
    setConfigurable[seq[DesktopKind]](
      "vPkg.desktopKind", @[dkSway, dkGnome])
    let activePair = activeVariantArms("vPkg", "desktopKind")
    check activePair.len == 2
    check activePair[0].armValue == "dkSway"
    check activePair[1].armValue == "dkGnome"
    # And a single-element override picks just one arm, even when it's
    # not the source-first arm.
    setConfigurable[seq[DesktopKind]](
      "vPkg.desktopKind", @[dkPlasma])
    let activePlasma = activeVariantArms("vPkg", "desktopKind")
    check activePlasma.len == 1
    check activePlasma[0].armValue == "dkPlasma"
    # Restore the default so other tests in this binary aren't affected
    # by the override.
    resetConfigurable("vPkg.desktopKind")

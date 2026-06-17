## DSL-port M9.D acceptance — ``config:`` ``seq[Enum]`` configurables.
##
## Pins the M9.D contract for ``seq[Enum]`` scalar configurables —
## the second of the two M9.D additions (the first being the bare-enum
## form pinned by ``t_dsl_config_enum.nim``).
##
## NDEM1 (reproos-desktop) motivation: the spec calls for
## ``desktopKind: seq[DesktopKind] = @[dkSway, dkGnome, dkPlasma]``
## as a closure-affecting variant. v1 of NDEM1 ships ``seq[string]``
## as a workaround (silently passed through M2's filter). M9.D opens
## the path for migration to the typed form so cross-config validation
## (e.g. ``activeAtBoot in desktopKind``) becomes a compile-time
## predicate where possible.
##
## Coverage:
##
##   * ``recordConfigDefault[E: enum]`` (the ``seq[E]`` overload)
##     stores the registered seq element-wise (ords + value names).
##   * ``readConfigurable[E](key, fallback: seq[E])`` returns the
##     registered seq when the key + type match; falls back otherwise.
##   * ``setConfigurable[E: enum]`` (the ``seq[E]`` overload)
##     replaces the registered seq.
##   * ``inspectConfigurable`` exposes the captured ``seqEnumTypeName``
##     for diagnostic / inspection paths.

import std/[unittest]

import repro_project_dsl

type
  DesktopKind* = enum
    dkSway
    dkGnome
    dkPlasma

package nm1Pkg:
  config:
    desktopKind: seq[DesktopKind] = @[dkSway, dkGnome, dkPlasma]

suite "DSL-port M9.D — config: seq[Enum] configurables":

  test "default reads back as the registered seq exactly":
    # Reset before observing the default so cross-test poisoning from a
    # later override is impossible. ``resetConfigurable`` is idempotent
    # on a clean cell.
    resetConfigurable("nm1Pkg.desktopKind")
    let got = readConfigurable[DesktopKind](
      "nm1Pkg.desktopKind", newSeq[DesktopKind]())
    check got == @[dkSway, dkGnome, dkPlasma]
    # Length pin: a future code change that accidentally double-emits
    # the registration would surface here as a 6-element seq.
    check got.len == 3

  test "inspectConfigurable exposes seqEnum metadata":
    resetConfigurable("nm1Pkg.desktopKind")
    let stored = inspectConfigurable("nm1Pkg.desktopKind")
    check stored.kind == dskSeqEnum
    check stored.seqEnumTypeName == "DesktopKind"
    # Element-wise: every name + ord stored matches the source-order
    # spelling. Asserting the value names round-trip catches accidental
    # ord-only coercion (which would lose the ``$value`` provenance the
    # diagnostic surface relies on).
    check stored.seqEnumValueNames == @["dkSway", "dkGnome", "dkPlasma"]
    check stored.seqEnumOrds == @[ord(dkSway), ord(dkGnome), ord(dkPlasma)]

  test "setConfigurable replaces the seq":
    setConfigurable[seq[DesktopKind]](
      "nm1Pkg.desktopKind", @[dkSway])
    let got = readConfigurable[DesktopKind](
      "nm1Pkg.desktopKind", newSeq[DesktopKind]())
    check got == @[dkSway]
    check got.len == 1

  test "resetConfigurable restores the registered default":
    setConfigurable[seq[DesktopKind]](
      "nm1Pkg.desktopKind", @[dkGnome, dkPlasma])
    # Sanity: the override took effect before reset.
    let beforeReset = readConfigurable[DesktopKind](
      "nm1Pkg.desktopKind", newSeq[DesktopKind]())
    check beforeReset == @[dkGnome, dkPlasma]
    resetConfigurable("nm1Pkg.desktopKind")
    let got = readConfigurable[DesktopKind](
      "nm1Pkg.desktopKind", newSeq[DesktopKind]())
    check got == @[dkSway, dkGnome, dkPlasma]

  test "missing-key read returns fallback":
    # Same graceful-degradation contract the scalar enum overload pins —
    # callers can probe possibly-unregistered keys without exception
    # bookkeeping.
    let fb = @[dkPlasma]
    check readConfigurable[DesktopKind](
      "nm1Pkg.nonExistentField", fb) == fb

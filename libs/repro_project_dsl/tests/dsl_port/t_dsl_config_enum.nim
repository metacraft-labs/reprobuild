## DSL-port M9.D acceptance — ``config:`` typed-enum configurables.
##
## Pins the M9.D contract for typed-enum scalar configurables. The M2
## surface previously supported only ``bool`` / ``int`` / ``string`` /
## ``float`` (and sized variants); M9.D widens the runtime + the
## ``package`` macro's emission filter to also handle user-defined
## ``enum`` types whose ord values are dense from 0.
##
## Coverage:
##
##   * ``recordConfigDefault[T]`` records the default ord + the
##     enum type name (``$T``) + the literal value name (``$value``).
##   * ``readConfigurable[T]`` round-trips the ord back to the original
##     enum value when the type matches.
##   * ``setConfigurable[T]`` propagates an override that subsequent
##     reads observe.
##   * The fallback overload returns the registered value when the
##     type matches and ``fallback`` when it does not.
##   * The ``inspectConfigurable`` accessor exposes the captured
##     ``enumTypeName`` / ``enumValueName`` for diagnostic / inspection
##     code paths.
##
## NDE0-D rewrite motivation: dbus-broker's spec calls for
## ``busActivationStrategy: BusActivationStrategy = dbusBroker``. The
## NDE0-D recipe (and every downstream NDEM consumer) needs the typed
## form so cross-config validation can rely on the compiler instead of
## ad-hoc parse + raise pairs.

import std/[unittest]

import repro_project_dsl

# Two enums declared at module scope so the ``package`` macro can see
# them when it expands the ``config:`` block. The enum literal names
# match the NDE0-D shim's spelling so a future migration to the
# enum-typed config block in ``recipes/packages/de-foundation/
# dbus-broker/repro.nim`` lands without renaming.
type
  BusActivationStrategy* = enum
    dbusBroker
    dbusDaemon

  LogLevel* = enum
    ## Second enum so the cross-type-fallback test has a non-trivial
    ## "wrong type" to probe with.
    logDebug
    logInfo
    logWarn

package dbusPkg:
  config:
    busActivationStrategy: BusActivationStrategy = dbusBroker

suite "DSL-port M9.D — config: typed enum configurables":

  test "default reads back as the registered enum literal":
    # Sanity: nothing else in the suite has run yet, so reset the cell
    # before observing the default. ``resetConfigurable`` is idempotent
    # on a clean cell.
    resetConfigurable("dbusPkg.busActivationStrategy")
    check readConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy") == dbusBroker

  test "fallback overload returns recorded default when type matches":
    # The fallback-flavoured overload still returns the recorded value
    # when the type matches; the fallback is only used on mismatch.
    check readConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy", dbusDaemon) == dbusBroker

  test "setConfigurable propagates to the next read":
    setConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy", dbusDaemon)
    check readConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy") == dbusDaemon
    # And the fallback overload sees the override too.
    check readConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy", dbusBroker) == dbusDaemon

  test "resetConfigurable restores the default":
    setConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy", dbusDaemon)
    resetConfigurable("dbusPkg.busActivationStrategy")
    check readConfigurable[BusActivationStrategy](
      "dbusPkg.busActivationStrategy") == dbusBroker

  test "inspectConfigurable exposes captured enum metadata":
    # Tests rely on the captured type name + value name to verify the
    # generic macro emission preserved the exact source identifiers —
    # not coerced through ``int`` or stringified ord. Reset first so
    # we observe the default rather than a stale override.
    resetConfigurable("dbusPkg.busActivationStrategy")
    let stored = inspectConfigurable("dbusPkg.busActivationStrategy")
    check stored.kind == dskEnum
    check stored.enumTypeName == "BusActivationStrategy"
    check stored.enumValueName == "dbusBroker"
    check stored.enumOrd == ord(dbusBroker)

  test "cross-type read returns fallback (graceful degradation)":
    # Reading an enum-valued cell as a different enum type via the
    # fallback overload must NOT raise — it returns the fallback.
    # This is the contract test fixtures + multi-recipe probe paths
    # depend on so they can robustly try multiple types without
    # exception bookkeeping.
    resetConfigurable("dbusPkg.busActivationStrategy")
    check readConfigurable[LogLevel](
      "dbusPkg.busActivationStrategy", logWarn) == logWarn

  test "missing-key read returns fallback":
    # The fallback overload also swallows ``EDslPortMissingKey`` —
    # otherwise the type-mismatch + missing-key code paths would have
    # different error semantics and callers would still need a try/except
    # wrapper for full graceful degradation.
    check readConfigurable[BusActivationStrategy](
      "nonExistentPkg.nonExistentField", dbusDaemon) == dbusDaemon

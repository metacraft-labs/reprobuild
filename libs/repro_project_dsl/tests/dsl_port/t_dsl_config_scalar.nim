## DSL-port M2 acceptance — ``config:`` scalar configurables (default).
##
## Pins the contract for M2's v8-style ``config:`` block. The block
## declares named scalar configurables with a default value; reading
## them via ``readConfigurable[T]("<package-id>.<name>")`` from the host
## program returns the default when nothing has overridden the slot.
##
## Public surface introduced by M2 (see
## ``libs/repro_project_dsl/src/repro_project_dsl/dsl_port_runtime.nim``):
##
##   * ``recordConfigDefault*[T](packageName, name: string; default: T)``
##     — the runtime call the ``config:`` lowerer emits, one per scalar
##     entry. Idempotent: re-recording the same ``(packageName, name)``
##     pair leaves the existing default in place so module-init replays
##     (e.g. unit tests that re-evaluate the package macro) do not
##     clobber a previously-overridden cell.
##   * ``readConfigurable*[T](key: string): T`` — read the scalar by its
##     ``<packageName>.<name>`` key, returns the default when no
##     override is pending. Raises if the key is unknown or the type
##     does not match what was registered.
##   * ``setConfigurable*[T](key: string; value: T)`` — override the
##     cell. Subsequent ``readConfigurable`` calls see ``value``.
##   * ``resetConfigurable*(key: string)`` — clear any override so the
##     default re-emerges. Used by tests so cross-test poisoning is
##     impossible.
##
## The keying scheme is ``<packageName>.<bindingName>`` (verbatim — no
## kebab translation in M2 — sub-agents can keep the test stable
## regardless of how the wrapping scheme evolves). ``configPkg`` is the
## Nim identifier the author wrote; that is the package name the legacy
## ``parsePackageDef`` carries forward.

import std/[unittest]

import repro_project_dsl

# The ``config:`` block in this package declares three scalar
# configurables. The M2 emitter wires each entry into
# ``recordConfigDefault`` at module-init time so the test below reads
# the defaults without doing any additional setup.
package configPkg:
  config:
    databasePort: int = 5432
    databaseHost: string = "localhost"
    enableTls: bool = true

suite "DSL-port M2 — config: scalar configurables":

  test "config: scalar reads int default value":
    check readConfigurable[int]("configPkg.databasePort") == 5432

  test "config: scalar reads string default value":
    check readConfigurable[string]("configPkg.databaseHost") == "localhost"

  test "config: scalar reads bool default value":
    check readConfigurable[bool]("configPkg.enableTls") == true

  test "registered keys enumerate via registeredConfigKeys":
    # ``registeredConfigKeys`` is M2's diagnostic accessor: returns the
    # full list of ``<package>.<name>`` keys recorded so far. Used by
    # the runner / repro deps refresh to verify all expected slots
    # exist. The order is insertion order; tests guard against accidental
    # name drift.
    let keys = registeredConfigKeys()
    check "configPkg.databasePort" in keys
    check "configPkg.databaseHost" in keys
    check "configPkg.enableTls" in keys

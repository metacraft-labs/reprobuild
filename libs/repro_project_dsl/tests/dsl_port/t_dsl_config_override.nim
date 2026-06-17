## DSL-port M2 acceptance — ``config:`` override propagation.
##
## Pins the contract for the override path. M2's M3+-compatible shape:
## ``setConfigurable`` writes into a per-key override table that
## ``readConfigurable`` consults BEFORE falling back to the registered
## default. ``resetConfigurable`` clears the override so other tests in
## the same process don't see a poisoned value.
##
## This is a stripped-down Cell pattern — full Cell-backed configurables
## (with the ConfigContext priority lattice) land in M3. M2 only needs
## the read/write surface so authors can prototype ``config:`` blocks
## end-to-end before the solver-backed pathway lights up.

import std/[unittest]

import repro_project_dsl

# Single int configurable; the test alternates between default,
# override, and reset.
package overridePkg:
  config:
    timeoutMs: int = 1000

suite "DSL-port M2 — config: override":

  test "default reads back as the registered literal":
    # Make sure nothing in the suite ran before us and poisoned the
    # cell. ``resetConfigurable`` is idempotent on a clean cell.
    resetConfigurable("overridePkg.timeoutMs")
    check readConfigurable[int]("overridePkg.timeoutMs") == 1000

  test "setConfigurable propagates to the next read":
    setConfigurable("overridePkg.timeoutMs", 5000)
    check readConfigurable[int]("overridePkg.timeoutMs") == 5000

  test "resetConfigurable restores the default":
    setConfigurable("overridePkg.timeoutMs", 9999)
    check readConfigurable[int]("overridePkg.timeoutMs") == 9999
    resetConfigurable("overridePkg.timeoutMs")
    check readConfigurable[int]("overridePkg.timeoutMs") == 1000

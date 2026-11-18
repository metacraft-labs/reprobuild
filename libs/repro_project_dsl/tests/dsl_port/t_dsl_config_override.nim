## DSL-port M2 acceptance — ``config:`` override propagation, and the
## spelling of the key an override names (`package.<name>.<leaf>`).
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

import std/[strutils, unittest]

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
    resetConfigurable("package.overridePkg.timeoutMs")
    check readConfigurable[int]("package.overridePkg.timeoutMs") == 1000

  test "setConfigurable propagates to the next read":
    setConfigurable("package.overridePkg.timeoutMs", 5000)
    check readConfigurable[int]("package.overridePkg.timeoutMs") == 5000

  test "resetConfigurable restores the default":
    setConfigurable("package.overridePkg.timeoutMs", 9999)
    check readConfigurable[int]("package.overridePkg.timeoutMs") == 9999
    resetConfigurable("package.overridePkg.timeoutMs")
    check readConfigurable[int]("package.overridePkg.timeoutMs") == 1000

  test "an unknown leaf is rejected, not skipped":
    expect EDslPortMissingKey:
      setConfigurable("package.overridePkg.timeoutSecs", 5)

  test "an unknown package is rejected, not skipped":
    expect EDslPortMissingKey:
      setConfigurable("package.noSuchPkg.timeoutMs", 5)

# The key's spelling. Configurable-System.md §"2. Scope-derived name
# (default persistence key)" names a package's configurable
# `package.<name>[.<scope>…].<leaf>` -- kind first, so a package and an
# activity of the same name cannot collide -- and Package-Model.md
# §"Directory-Scoped Rule Generators" addresses an override by exactly
# that name. This lane used to register `<name>.<leaf>`, so the spec's own
# worked-example key named no configurable (reprobuild-pm issue
# 2026-11-17-dsl-port-configurable-keys-omit-the-package-kind-prefix).
suite "DSL-port — a configurable key begins with its kind":

  test "the scope-derived key `package.<name>.<leaf>` is the registered key":
    check isConfigKeyRegistered("package.overridePkg.timeoutMs")
    setConfigurable("package.overridePkg.timeoutMs", 4321)
    check readConfigurable[int]("package.overridePkg.timeoutMs") == 4321
    resetConfigurable("package.overridePkg.timeoutMs")

  test "the key without its kind segment names no configurable":
    check not isConfigKeyRegistered("overridePkg.timeoutMs")
    var message = ""
    try:
      setConfigurable("overridePkg.timeoutMs", 5)
    except EDslPortMissingKey as e:
      message = e.msg
    check message.len > 0
    # The refusal points at the key the author meant.
    check "did you mean 'package.overridePkg.timeoutMs'" in message
    check readConfigurable[int]("package.overridePkg.timeoutMs") == 1000

  test "a fallback reader does not answer a kindless key with its fallback":
    # `readConfigurable(key, fallback)` answers an ABSENT key with the
    # fallback. A registered key with its kind left off is a misspelling:
    # answering it with the fallback would leave every override of the
    # configurable unread while the build reports success.
    setConfigurable("package.overridePkg.timeoutMs", 7777)
    expect EDslPortMissingKey:
      discard readConfigurable[int]("overridePkg.timeoutMs", 1)
    check readConfigurable[int]("package.overridePkg.timeoutMs", 1) == 7777
    check readConfigurable[int]("package.noSuchPkg.timeoutMs", 1) == 1
    resetConfigurable("package.overridePkg.timeoutMs")

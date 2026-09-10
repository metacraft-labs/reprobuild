import std/[sequtils, unittest]
import repro_project_dsl
import fixtures/explicit_contract/consumer/repro as consumerFixture
import fixtures/explicit_contract/fallback_consumer/repro as fallbackFixture

suite "explicit contract import precedence":
  test "explicit contract excludes the workspace implementation":
    check consumerFixture.selectedContract() == "explicit-contract"

  test "implicit contract retains workspace fallback":
    check registeredPackages().anyIt(it.packageName == "fixture_fallback")

  test "empty import path retains workspace fallback":
    check registeredPackages().anyIt(it.packageName == "fixture_empty")

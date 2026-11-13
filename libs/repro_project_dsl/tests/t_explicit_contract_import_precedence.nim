import std/[sequtils, unittest]
import repro_project_dsl
import fixtures/explicit_contract/consumer/repro as consumerFixture
import fixtures/explicit_contract/fallback_consumer/repro as fallbackFixture
import fixtures/explicit_contract/beside_path_consumer/repro as besidePathFixture

suite "explicit contract import precedence":
  test "explicit contract excludes the workspace implementation":
    check consumerFixture.selectedContract() == "explicit-contract"

  test "implicit contract retains workspace fallback":
    check registeredPackages().anyIt(it.packageName == "fixture_fallback")

  test "empty import path retains workspace fallback":
    check registeredPackages().anyIt(it.packageName == "fixture_empty")

  test "an explicit import path leaves a sibling it holds no module for to the workspace":
    # Before the rule, the path took every selector and the import of
    # `contracts/fixture_minimal` failed, so this file did not compile.
    check registeredPackages().anyIt(it.packageName == "besidePathConsumer")
    check registeredPackages().anyIt(it.packageName == "fixture_minimal")
    # The selector the path does hold is still taken from it: the workspace
    # `fixture_probe` recipe is a compile `{.error.}`, so importing it instead
    # would have failed this file's compilation too.

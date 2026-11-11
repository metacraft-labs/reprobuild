## Fixture for ``t_repro_build_unselected_omits_consumers_of_excluded_members``.
## The package lives in its own module because the provider-mode shim the
## ``package`` macro emits runs only in the main module; the test drives
## ``buildPackageFragment`` directly instead.

import repro_project_dsl

package unselectedExclusionFixture:
  build:
    discard buildAction("fixture.product",
      inlineExecCall(["/bin/true", "product"]),
      outputs = ["build/product"])
    let sdkProtocol = buildAction("fixture.sdk_protocol",
      inlineExecCall(["/bin/true", "sdk-protocol"]),
      outputs = ["build/sdk-protocol.stamp"])
    let sdkNative = buildAction("fixture.sdk_native",
      inlineExecCall(["/bin/true", "sdk-native"]),
      deps = [sdkProtocol.id],
      outputs = ["build/sdk-native.stamp"])
    discard buildAction("fixture.sdk_report",
      inlineExecCall(["/bin/true", "sdk-report"]),
      deps = [sdkNative.id],
      outputs = ["build/sdk-report.stamp"])
    discard collect("test", [sdkProtocol])
    discard collect("authoring", [sdkNative])

# ``cycle.a`` is declared before the excluded member it depends on, and
# it sits on a cycle with ``cycle.b``: the exclusion must reach both
# whatever order the actions are visited in.
package unselectedExclusionCycleFixture:
  build:
    discard buildAction("cycle.a",
      inlineExecCall(["/bin/true", "a"]),
      deps = ["cycle.b", "cycle.x"],
      outputs = ["build/cycle-a.stamp"])
    discard buildAction("cycle.b",
      inlineExecCall(["/bin/true", "b"]),
      deps = ["cycle.a"],
      outputs = ["build/cycle-b.stamp"])
    let member = buildAction("cycle.x",
      inlineExecCall(["/bin/true", "x"]),
      outputs = ["build/cycle-x.stamp"])
    discard buildAction("cycle.kept",
      inlineExecCall(["/bin/true", "kept"]),
      outputs = ["build/cycle-kept.stamp"])
    discard collect("test", [member])

export buildUnselectedExclusionFixturePackage
export buildUnselectedExclusionCycleFixturePackage

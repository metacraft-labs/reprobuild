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

export buildUnselectedExclusionFixturePackage

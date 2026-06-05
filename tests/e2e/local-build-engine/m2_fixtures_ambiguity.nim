## Named-Targets M2 ambiguity fixture: two packages each emit a
## typed-tool call whose implicit name is ``cli``. The packaging
## boilerplate (``runPackageProvider`` shim) only fires when the file
## is the main module; this file is always imported, so neither
## package's provider-mode quit shim runs at test time. The test
## drives ``buildPackageFragment`` directly to obtain two fragments.

import repro_project_dsl

defineCliInterface ambigTool, "test-ambig-tool":
  call:
    flag input is string, alias = "--input", role = input, required = true
    flag output is string, alias = "--output", role = output, required = true
    flag marker is string, alias = "--marker", required = true
    outputs output

package m2AmbigPkgA:
  uses:
    "test-ambig-tool >=1.0 <2.0"
  build:
    ambigTool(actionId = "build-cli-a",
      input = "src/cli-a.txt",
      output = "build/cli",
      marker = ".repro/m2-runs.log")

package m2AmbigPkgB:
  uses:
    "test-ambig-tool >=1.0 <2.0"
  build:
    ambigTool(actionId = "build-cli-b",
      input = "src/cli-b.txt",
      output = "build/cli",
      marker = ".repro/m2-runs.log")

export ambigTool
export buildM2AmbigPkgAPackage
export buildM2AmbigPkgBPackage

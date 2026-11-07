import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package exeprod:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "chmod"

  executable exeprod:
    name: "exeprod"

  build:
    let buildExe = shell(
      command = "mkdir -p build/bin && " &
        "printf '#!/bin/sh\necho SC7-EXEPRODUCER-STAMP-9d1e4b\n' > build/bin/exeprod && " &
        "chmod +x build/bin/exeprod",
      actionId = "exeprod.build.exeprod",
      extraOutputs = @["build/bin/exeprod"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(buildExe.id, ["mkdir", "chmod"])

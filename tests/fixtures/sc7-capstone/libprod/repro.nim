import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package libprod:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "cc"
    "cp"

  library scprodlib:
    kind: shared

  build:
    let buildLib = shell(
      command = "mkdir -p build/lib build/include && " &
        "cc -shared -fPIC -o build/lib/libscprodlib.so greeting.c && " &
        "cp greeting.h build/include/greeting.h",
      actionId = "libprod.build.scprodlib",
      extraInputs = @["greeting.c", "greeting.h"],
      extraOutputs = @["build/lib/libscprodlib.so", "build/include/greeting.h"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(buildLib.id, ["mkdir", "cc", "cp"])

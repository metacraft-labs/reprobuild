import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "cc"
    "exeprod"
    "libprod"

  build:
    let consume = shell(
      command = "mkdir -p build && " &
        "exeprod > build/exe.txt && " &
        "cc -o build/consume main.c -lscprodlib && " &
        "./build/consume",
      actionId = "consumer.build.consume",
      extraInputs = @["main.c"],
      extraOutputs = @["build/exe.txt", "build/consume", "build/consumed.txt"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(consume.id,
      ["exeprod", "libprod", "mkdir", "cc"])

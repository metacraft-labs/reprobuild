import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "exeprod"

  build:
    let consume = shell(
      command = "mkdir -p build && exeprod > build/exe.txt",
      actionId = "consumer.build.consume",
      extraOutputs = @["build/exe.txt"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(consume.id, ["exeprod", "mkdir"])

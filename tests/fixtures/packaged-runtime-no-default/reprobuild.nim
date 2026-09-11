## The NEGATIVE half of M1's flagless-build question.
##
## `packaged-runtime-compile` is the same project with one line added --
## `defaultToolProvisioning "path"` -- and it builds from an installed
## package with NO FLAGS. This one omits that line, and `repro build`
## must refuse it with the exact message below rather than silently
## resolving `gcc` and `sh` out of whatever the ambient PATH offers:
##
##   typed tool provisioning is required for uses declarations; refusing
##   implicit PATH fallback. Pass --tool-provisioning=path to use the
##   explicit weak local profile.
##
## The refusal is a correctness property and not a packaging artefact.
## An action's runtime PATH is composed only of the directories the
## solved graph resolved THAT EDGE's declared tools into; an implicit
## fallback would put an unrecorded host binary into a build whose cache
## key claims to name its inputs. So the tool asks the project to say
## which provisioning model it wants, once, and the answer is one line.
##
## Kept as a fixture rather than as an inline string in the gate script
## so that the message the gate asserts is the message a real recipe
## produces, through the real CLI, from an installed package.

import repro_dsl_stdlib

package reprobuildPackagedRuntimeNoDefault:
  uses:
    "gcc >=1"
    "sh >=1"

  executable shell:
    name "sh"
    cli:
      subcmd "-c":
        pos args is seq[string],
          position = 0

  executable cCompiler:
    name "gcc"
    cli:
      subcmd "-o":
        pos args is seq[string],
          position = 0

  build:
    let buildDir = fs.ensureDir(
      path = "build",
      actionId = "build-dir")

    let hello = buildAction(
      "compile-hello",
      reprobuildPackagedRuntimeNoDefault.executable("gcc").subcmd_2d_o(
        args = @["build/hello", "src/hello.c"]),
      deps = @["build-dir"],
      inputs = @["src/hello.c"],
      outputs = @["build/hello"])

    let output = buildAction(
      "run-hello",
      reprobuildPackagedRuntimeNoDefault.executable("sh").subcmd_2d_c(
        args = @["./build/hello > build/hello-output.txt"]),
      deps = @["compile-hello"],
      inputs = @["build/hello"],
      outputs = @["build/hello-output.txt"])

    target("hello", [buildDir, hello, output])
    defaultTarget(output)

import repro_dsl_stdlib

package reprobuildPackagedRuntime:
  # SAY HOW THE `uses:` BELOW ARE PROVISIONED, because a project that
  # declares tool uses and does not say is refused -- deliberately, and
  # not as a packaging artefact. `repro build` will not fall back to
  # whatever `gcc` and `sh` the ambient PATH happens to offer: the
  # action's PATH is composed only of directories the solved graph
  # resolved that edge's declared tools into, and an implicit fallback
  # would make the build non-hermetic and its cache keys wrong.
  #
  # `path` is the weak local profile -- resolve each declared tool by
  # executable NAME on the host -- which is the right mode for this
  # fixture and for the packaged-runtime gate: the point of that gate is
  # that an INSTALLED reprobuild can drive the target's own toolchain,
  # which arrives from the distribution's `gcc` and `libc6-dev`.
  #
  # This is also what makes a packaged `repro build` work WITH NO FLAGS.
  # It is one line in the recipe -- reprobuild's own `repro.nim` carries
  # the same one -- and it is the answer to "should a packaged repro
  # need a flag no other packaged tool needs": it should not, and it
  # does not, once the project says what it wants.
  defaultToolProvisioning "path"

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
      reprobuildPackagedRuntime.executable("gcc").subcmd_2d_o(
        args = @["build/hello", "src/hello.c"]),
      deps = @["build-dir"],
      inputs = @["src/hello.c"],
      outputs = @["build/hello"])

    let output = buildAction(
      "run-hello",
      reprobuildPackagedRuntime.executable("sh").subcmd_2d_c(
        args = @["./build/hello > build/hello-output.txt"]),
      deps = @["compile-hello"],
      inputs = @["build/hello"],
      outputs = @["build/hello-output.txt"])

    target("hello", [buildDir, hello, output])
    defaultTarget(output)

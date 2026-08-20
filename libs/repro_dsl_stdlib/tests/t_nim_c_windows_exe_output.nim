## `nim.c` must declare the file nim actually writes.
##
## The Windows C backend appends `.exe` to the executable it links whether or
## not `--out:` already carries the extension: `--out:foo` yields `foo.exe`.
## `nim.c` passed its `binary` argument straight through as the action's
## declared output (`role = output`, `outputs output` in the CLI spec), so on
## Windows every executable edge declared a path that never came into
## existence.
##
## That is not a cosmetic mismatch. The engine captures declared outputs into
## the CAS after a successful run, and it takes the outputs-present fast path
## on a cache hit by checking that they exist. With the declared name pointing
## at nothing, neither could happen: records were published without payloads,
## and a lookup whose fingerprint matched then failed with "cache record does
## not contain output payloads" and re-ran the action. Every nim executable
## edge on Windows was permanently uncacheable for this reason alone --
## `harness_apply_lock_holder` took 76s cold and 76s warm, and takes 4s warm
## now.
##
## The assertions below pin the declared output and the argv together, because
## the bug is precisely a disagreement between the two: a fix that suffixed
## only the declaration would leave `--out:` naming a different file.

import std/[options, os, strutils, unittest]

import repro_project_dsl
# Imported under an alias on purpose: the `package nim:` block inside this
# module emits a const named `nim`, and a plain `import` would shadow it with
# the module name and break `nim.c(...)` resolution -- the same reason
# reprobuild's own `repro.nim` reaches the const through the `uses:` pass.
import repro_dsl_stdlib/packages/nim as nim_module
import repro_dsl_stdlib/types

const nimTool = nim_module.nim

proc outArgOf(act: BuildActionDef): string =
  ## The value nim is told to write. The CLI spec marks this parameter
  ## `role = output`, which is both what lands in argv as `--out:` and what
  ## `outputs output` declares -- so reading the role is reading the single
  ## source the two are derived from.
  for arg in act.call.arguments:
    if arg.role == carOutput:
      return arg.encodedValue
  ""

suite "nim.c declares the binary nim really produces":

  test "an executable edge declares the linked file":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "tools" / "declared.nim",
      binary = "build" / "bin" / "declared")

    when defined(windows):
      # Before the fix this was `build\bin\helper`, which nim never created.
      check act.outputs == @["build" / "bin" / "declared.exe"]
    else:
      check act.outputs == @["build" / "bin" / "declared"]

  test "the declared output and --out: name the same file":
    # The invariant that matters, stated without reference to a platform:
    # whatever the edge declares, that is what nim is asked to write.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "tools" / "agree.nim",
      binary = "build" / "bin" / "agree")
    check act.outputs.len == 1
    check outArgOf(act) == act.outputs[0]

  test "an explicit .exe is not suffixed twice":
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "tools" / "explicit.nim",
      binary = "build" / "bin" / "explicit.exe")
    check act.outputs == @["build" / "bin" / "explicit.exe"]

  test "a library edge keeps the extension its recipe spelled out":
    # `--app:lib` yields `.dll`, and library recipes already write the
    # extension; suffixing `.exe` here would break them.
    resetBuildActionRegistry()
    let act = nimTool.c(
      source = "src" / "shim.nim",
      binary = "build" / "lib" / "shim.dll",
      appLib = true)
    check act.outputs == @["build" / "lib" / "shim.dll"]

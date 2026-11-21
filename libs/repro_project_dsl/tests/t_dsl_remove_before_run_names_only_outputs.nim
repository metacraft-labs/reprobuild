## ``cli: removeBeforeRun <flag>`` names only the tool's OUTPUT parameters.
##
## The engine removes each path the declaration names before the edge runs,
## for a tool that refuses to write over its previous output (create-dmg's
## ``hdiutil convert``). What keeps that removal to paths the edge owns is
## that only a ``role = output`` parameter may be named, and the macro checks
## it where the tool author can still see the declaration. A flag that is an
## input, or that does not exist in the scope, fails compilation with a
## diagnostic naming it.
##
## Compile real modules: `package` cannot expand inside a `compiles` block,
## even for valid input. The positive control proves the compiler accepts the
## legal declaration before each refusal's diagnostic is inspected.
## No mocks: the shared probe invokes the real Nim compiler on repository files.

import std/unittest
import ./dsl_port/service_block_compile_probe

proc recipe(removed: string; directive = "removeBeforeRun"): string =
  ## A one-tool package whose `cli:` declares `removeBeforeRun <removed>`
  ## over an output positional `image` and an input positional `source`.
  "import repro_project_dsl\n" &
    "package tDslRemoveBeforeRun:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  executable tool:\n" &
    "    cli:\n" &
    "      pos image is string, role = output\n" &
    "      pos source is string, role = input\n" &
    "      outputs image\n" &
    "      " & directive & " " & removed & "\n"

suite "t_dsl_remove_before_run_names_only_outputs":
  test "an output parameter is accepted":
    let accepted = checkRecipeSource(recipe("image"),
      "remove-before-run-output")
    checkpoint accepted.output
    check accepted.ok

  test "an input parameter is refused":
    let rejected = checkRecipeSource(recipe("source"),
      "remove-before-run-input")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("removeBeforeRun: 'source' is not an output")
    check rejected.mentions("recipe.nim(10, 23) Error: removeBeforeRun:")

  test "an unknown parameter is refused":
    let rejected = checkRecipeSource(recipe("missing"),
      "remove-before-run-unknown")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("removeBeforeRun: 'missing' is not a flag or " &
      "positional visible in this cli scope")

  test "optional output declaration accepts an output parameter":
    let accepted = checkRecipeSource(recipe("image", "optionalOutputs"),
      "optional-output-accepted")
    checkpoint accepted.output
    check accepted.ok

  test "optional output declaration refuses input and unknown parameters":
    for name in ["source", "missing"]:
      let rejected = checkRecipeSource(recipe(name, "optionalOutputs"),
        "optional-output-refused-" & name)
      checkpoint rejected.output
      check not rejected.ok
      check rejected.mentions("optionalOutputs: '" & name & "' is not")

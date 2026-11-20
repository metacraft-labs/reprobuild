## The ``envPassthrough`` directive of a ``cli:`` block: what a tool package
## can say, what its nested scopes inherit, what the generated typed wrapper
## stamps on every edge, and what the parser REFUSES.
##
## A tool whose process reads an environment variable only to place
## disposable files -- the temp-directory names a compiler reads -- declares
## the names once, in its own ``cli:`` block:
##
##   envPassthrough "TMPDIR", "TMP"
##   envPassthrough ScratchLocationEnvNames      # a const list, by name
##
## Every edge the generated wrapper records then carries them in
## ``BuildActionDef.envPassthrough`` (keyed by name, never by value;
## reprobuild-pm ``spec/Filesystem-Policy-And-Observed-Inputs.md``
## §"Declared And Passthrough Variables"). The ``nim`` tool's own declaration
## is pinned by ``t_nim_c_scratch_env_passthrough``; this file pins the
## SURFACE, on both doors onto a ``cli:`` declaration (``package … :
## executable … : cli:`` and the transitional ``defineCliInterface``), since a
## clause wired into one and not the other is ignored with no diagnostic.
##
## # Why the refusals are checked through the real compiler
##
## The literal-name refusals are ``macros.error`` calls, and the refusal of a
## bad name inside a referenced const list is a ``{.error.}`` in the
## generated wrapper; ``compiles()`` cannot see either, because ``package``
## and ``defineCliInterface`` are top-level declarations. The probe is the
## repo's ``lock_file_compile_probe`` (real ``nim check`` over a recipe
## written under ``build/``), as ``t_da6_capture_breadth_dsl_surface`` does,
## and the assertions are on the diagnostic's CONTENT: a probe that stopped
## compiling for an unrelated reason would satisfy "it failed" and none of
## the requirement. A positive control compiles the same recipe text with a
## legal declaration first.
##
## # Mocks
##
## NONE. The tools are declared with the real macros in
## ``cli_env_passthrough_fixtures``, their edges are read off the real
## registry, and the refusals are the real compiler's exit code and stderr.

import std/[strutils, unittest]

import repro_project_dsl

import ./cli_env_passthrough_fixtures
import ./lock_file_compile_probe

proc registeredEdge(id: string): BuildActionDef =
  ## The LAST registration under `id`: the one the graph is built from.
  let actions = registeredBuildActions()
  for i in countdown(actions.high, 0):
    if actions[i].id == id:
      return actions[i]
  raise newException(KeyError, "no registered action " & id)

const RunNames = @["ROOT_SCRATCH", "RUN_SCRATCH",
  "FIXTURE_SCRATCH_A", "FIXTURE_SCRATCH_B"]
  ## What the fixtures' `run` subcommand declares, inherited root name first,
  ## each name once: the literal names in declaration order, then the names
  ## of the referenced const list.

suite "the envPassthrough directive parses, accumulates and is inherited":

  setup:
    resetBuildActionRegistry()
    resetTargetExportRegistry()

  test "the package door: a nested subcmd accumulates, deduplicated":
    let act = envpassprobe.run(output = "build/run.bin")
    check act.envPassthrough == RunNames
    check registeredEdge(act.id).envPassthrough == RunNames

  test "the package door: a subcmd that declares nothing inherits the root":
    let act = envpassprobe.plain(output = "build/plain.bin")
    check act.envPassthrough == @["ROOT_SCRATCH"]
    check registeredEdge(act.id).envPassthrough == @["ROOT_SCRATCH"]

  test "the defineCliInterface door: the same accumulation":
    let act = envPassIface.run(output = "build/iface-run.bin")
    check act.envPassthrough == RunNames
    check registeredEdge(act.id).envPassthrough == RunNames

  test "the defineCliInterface door: the same inheritance":
    let act = envPassIface.plain(output = "build/iface-plain.bin")
    check act.envPassthrough == @["ROOT_SCRATCH"]
    check registeredEdge(act.id).envPassthrough == @["ROOT_SCRATCH"]

  test "a tool that declares nothing names nothing":
    ## The empty declaration is the identity: no edge of a tool that never
    ## heard of the directive changes key.
    let act = envPassSilent.run(output = "build/silent.bin")
    check act.envPassthrough.len == 0
    check registeredEdge(act.id).envPassthrough.len == 0

  test "the names are passthrough, not declared values":
    let act = envpassprobe.run(output = "build/run-env.bin",
      extraEnv = @[("RUN_SCRATCH", "/declared")])
    let edge = registeredEdge(act.id)
    check edge.envPassthrough == RunNames
    # A declared value is still allowed beside the passthrough name (the
    # spec's "passthrough and carry a declared value" case), and nothing the
    # directive adds becomes a declared value.
    check ("RUN_SCRATCH", "/declared") in edge.env
    for (name, _) in edge.env:
      check name notin ["ROOT_SCRATCH", "FIXTURE_SCRATCH_A",
        "FIXTURE_SCRATCH_B"]

  test "an edge can add its own names, and cannot remove the tool's":
    var act = envpassprobe.run(output = "build/run-extra.bin")
    appendRegisteredActionEnvPassthrough(act, ["EDGE_ONLY", "ROOT_SCRATCH"])
    check registeredEdge(act.id).envPassthrough == RunNames & @["EDGE_ONLY"]
    # No formal parameter of the wrapper names the list, so a call site can
    # neither drop the tool's declaration nor replace it.
    check not compiles(envpassprobe.run(output = "build/x.bin",
      envPassthrough = newSeq[string]()))
    check not compiles(envPassIface.run(output = "build/x.bin",
      envPassthrough = newSeq[string]()))

  test "the names survive the payload round trip":
    let act = envpassprobe.run(output = "build/run-payload.bin")
    check decodeBuildActionPayload(encodeBuildActionPayload(
      registeredEdge(act.id))).envPassthrough == RunNames

proc packageRecipeWith(line: string): string =
  ## A minimal, otherwise-valid `package` recipe whose `cli:` subcommand
  ## carries `line`. The `\n` after `line` is explicit, for the reason
  ## `t_da6_capture_breadth_dsl_surface.recipeWith` gives.
  "import repro_project_dsl\n" &
    "\n" &
    "const ProbeNames = [\"PROBE_SCRATCH\", \"PATH\"]\n" &
    "const EmptyNamed = [\"\"]\n" &
    "const GoodNames = [\"PROBE_SCRATCH\"]\n" &
    "\n" &
    "package envpassrefusal:\n" &
    "  executable envpassrefusal:\n" &
    "    cli:\n" &
    "      subcmd \"run\":\n" &
    "        " & line & "\n" &
    "        flag output is string,\n" &
    "          alias = \"-o\",\n" &
    "          role = output,\n" &
    "          required = true\n" &
    "        outputs output\n"

proc interfaceRecipeWith(line: string): string =
  ## The same, through the `defineCliInterface` door.
  "import repro_project_dsl\n" &
    "\n" &
    "defineCliInterface probeTool, \"envpass-refusal\":\n" &
    "  " & line & "\n" &
    "  subcmd \"run\":\n" &
    "    flag output is string,\n" &
    "      alias = \"-o\",\n" &
    "      role = output,\n" &
    "      required = true\n" &
    "    outputs output\n"

suite "the envPassthrough directive refuses what it cannot honour":

  test "legal declarations compile -- the positive controls":
    ## FIRST: every refusal below is worthless if this text does not compile
    ## for an unrelated reason.
    let literal = checkRecipeSource(
      packageRecipeWith("envPassthrough \"PROBE_SCRATCH\""), "envpass-ok")
    if not literal.ok:
      echo "the package-door POSITIVE control did not compile:\n",
        literal.output
    check literal.ok
    let viaConst = checkRecipeSource(
      packageRecipeWith("envPassthrough GoodNames"), "envpass-ok-const")
    if not viaConst.ok:
      echo "the const-reference POSITIVE control did not compile:\n",
        viaConst.output
    check viaConst.ok
    let iface = checkRecipeSource(
      interfaceRecipeWith("envPassthrough \"PROBE_SCRATCH\""),
      "envpass-iface-ok")
    if not iface.ok:
      echo "the defineCliInterface POSITIVE control did not compile:\n",
        iface.output
    check iface.ok

  test "PATH is refused, and the diagnostic says why":
    for (recipe, tag) in [
        (packageRecipeWith("envPassthrough \"TMPDIR\", \"PATH\""),
          "envpass-path"),
        (packageRecipeWith("envPassthrough \"Path\""), "envpass-path-case"),
        (interfaceRecipeWith("envPassthrough \"PATH\""),
          "envpass-iface-path")]:
      let probe = checkRecipeSource(recipe, tag)
      checkpoint(tag & ":\n" & probe.output)
      check not probe.ok
      check "envPassthrough cannot name" in probe.output
      check "tool references" in probe.output

  test "an empty name is refused, and the diagnostic says why":
    for (recipe, tag) in [
        (packageRecipeWith("envPassthrough \"TMPDIR\", \"\""),
          "envpass-empty"),
        (interfaceRecipeWith("envPassthrough \"\""), "envpass-iface-empty")]:
      let probe = checkRecipeSource(recipe, tag)
      checkpoint(tag & ":\n" & probe.output)
      check not probe.ok
      check "envPassthrough cannot name an empty variable" in probe.output

  test "a bad name inside a referenced const list is refused too":
    ## The const is resolved where the wrapper is compiled, so its names are
    ## checked there; a list smuggling `PATH` or an empty name in must fail
    ## the same way a literal does.
    let path = checkRecipeSource(
      packageRecipeWith("envPassthrough ProbeNames"), "envpass-const-path")
    checkpoint(path.output)
    check not path.ok
    check "envPassthrough cannot name" in path.output
    check "tool references" in path.output
    let empty = checkRecipeSource(
      packageRecipeWith("envPassthrough EmptyNamed"), "envpass-const-empty")
    checkpoint(empty.output)
    check not empty.ok
    check "envPassthrough cannot name an empty variable" in empty.output

  test "a directive with no names, or a non-name operand, is refused":
    let bare = checkRecipeSource(packageRecipeWith("envPassthrough"),
      "envpass-bare")
    checkpoint(bare.output)
    check not bare.ok
    check "envPassthrough expects" in bare.output
    let wrongKind = checkRecipeSource(packageRecipeWith("envPassthrough 3"),
      "envpass-int")
    checkpoint(wrongKind.output)
    check not wrongKind.ok
    check "envPassthrough expects" in wrongKind.output

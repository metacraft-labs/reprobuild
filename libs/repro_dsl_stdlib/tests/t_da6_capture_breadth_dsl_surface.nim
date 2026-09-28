## DA-6 — the DSL surface of the capture-breadth declaration: what a tool
## package can say, what it inherits, and what the parser REFUSES.
##
## # What this file is for
##
## `tests/integration/t_da6_tool_capture_breadth_declarations.nim` checks the
## declarations the stdlib's tool packages actually made.
## `libs/repro_build_engine/tests/t_da6_declared_interest_keeps_every_consumer.nim`
## checks that no declaration can cost a consumer its evidence. Neither of them
## can check the third thing DA-6 changed, which is the SURFACE:
##
##   * `captureBreadth = fullCapture` / `= omitAmbientReads` parses, and reaches
##     a registered edge rather than stopping at the parser;
##   * it is INHERITED by nested `subcmd` scopes the way the rest of
##     `dependencyPolicy` is, which is what makes it a property of the TOOL
##     rather than of one subcommand;
##   * `captureNonDeterminism` still parses, and now MEANS something — the scope
##     DA-5 sanctioned for it and nothing else: `false` excludes the ambient
##     reads, `true` keeps them. It is the field that spent a milestone marked
##     INERT while carrying a comment that had become false;
##   * `captureIpc` is REFUSED, by name, with a diagnostic that says why and what
##     to write instead;
##   * an unrecognised breadth word is refused rather than silently inherited.
##
## # Why the refusals are checked through the real compiler
##
## Both refusals are `macros.error` calls, so the only honest test of them is a
## compiler exit code over real source text — `compiles()` cannot be used because
## `defineCliInterface` / `package` are top-level declarations. The probe is the
## repo's existing `lock_file_compile_probe`, which writes a recipe under
## `build/` (so this repo's `config.nims` governs the module path) and runs the
## real `nim check`.
##
## AND THE ASSERTION IS ON THE DIAGNOSTIC'S CONTENT, not merely on failure. A
## recipe that stopped compiling with `undeclared identifier` would satisfy "it
## failed" and none of the requirement: the whole reason `captureIpc` is an error
## instead of a silently-ignored named argument is that its author believes they
## narrowed or widened something, and only a sentence tells them otherwise.
##
## # Mocks
##
## NONE. The tools below are declared with the real `defineCliInterface` macro
## and their breadth is read off a registered `BuildActionDef`; the refusals are
## the real `nim check` exit code and its real stderr.

import std/[strutils, unittest]

import repro_core
import repro_project_dsl

import ./lock_file_compile_probe

# A declaration at the ROOT of the `cli:` scope, plus a nested `subcmd`, so the
# inheritance rule is asserted on a real registered edge rather than on the
# parser's local variable.
defineCliInterface narrowedTool, "da6-narrowed":
  dependencyPolicy automaticMonitor,
    captureBreadth = omitAmbientReads
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

defineCliInterface fullTool, "da6-full":
  dependencyPolicy automaticMonitor,
    captureBreadth = fullCapture
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

defineCliInterface silentTool, "da6-silent":
  dependencyPolicy automaticMonitor
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

# The legacy spelling, in both polarities. `false` is the interesting one: it is
# the value DA-5 said this field could honourably mean ("exclude
# `ecAmbientReads`, and nothing else"), and the polarity is the one the field's
# own name states.
defineCliInterface legacyFalseTool, "da6-legacy-false":
  dependencyPolicy automaticMonitor,
    captureNonDeterminism = false
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

defineCliInterface legacyTrueTool, "da6-legacy-true":
  dependencyPolicy automaticMonitor,
    captureNonDeterminism = true
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

proc recipeWith(policyLine: string): string =
  ## A minimal, otherwise-valid recipe carrying one `dependencyPolicy`
  ## declaration. Otherwise-valid matters: a probe whose source is broken for
  ## some second reason proves nothing about the clause under test, so the
  ## POSITIVE control below compiles this same text with a legal declaration.
  ## The `\n` after `policyLine` is EXPLICIT on purpose: Nim's triple-quoted
  ## literal swallows the newline that immediately follows its opening `"""`, so
  ## a naive three-segment concatenation glues `<policyLine>  subcmd "run":`
  ## onto one line, the recipe parser reads `subcmd` as a continuation of the
  ## declaration's argument list, and EVERY case in this suite fails with the
  ## same diagnostic — including the positive control, which is how the mistake
  ## was caught rather than shipped.
  "import repro_project_dsl\n" &
    "\n" &
    "defineCliInterface probeTool, \"da6-probe\":\n" &
    "  dependencyPolicy automaticMonitor,\n" &
    "    " & policyLine & "\n" &
    "  subcmd \"run\":\n" &
    "    flag output is string,\n" &
    "      alias = \"-o\",\n" &
    "      role = output,\n" &
    "      required = true\n" &
    "    outputs output\n"

proc packageRecipeWith(policyLine: string): string =
  ## The SECOND door onto a `dependencyPolicy` declaration: `package … :
  ## executable … : cli:`, parsed by `parseCommandDependencyPolicy`, which is a
  ## different proc from the `defineCliInterface` parser `recipeWith` exercises.
  ## Both doors are probed because a clause wired into one and not the other is
  ## ignored with no diagnostic at all — and the tool packages this milestone
  ## edited all go through THIS one.
  "import repro_project_dsl\n" &
    "\n" &
    "package da6probe:\n" &
    "  executable da6probe:\n" &
    "    cli:\n" &
    "      dependencyPolicy automaticMonitor,\n" &
    "        " & policyLine & "\n" &
    "      subcmd \"run\":\n" &
    "        flag output is string,\n" &
    "          alias = \"-o\",\n" &
    "          role = output,\n" &
    "          required = true\n" &
    "        outputs output\n"

suite "DA-6 the capture-breadth declaration parses and is inherited":

  test "a declared narrowing reaches a nested subcmd's edge":
    ## The declaration is written ONCE at the `cli:` root and has to reach every
    ## subcommand, which is what makes it a statement about the tool. Asserted
    ## on a registered edge because that is where a declaration that parsed but
    ## did not travel would still look right in the source.
    resetBuildActionRegistry()
    let act = narrowedTool.run(output = "build/out.bin")
    check act.dependencyPolicy.captureBreadth == mcbOmitAmbientReads

  test "a declared full capture reaches one too":
    ## The other word, and it is not redundant with the default: the value is
    ## the same but the ROUTE is different, and a parser arm that dropped
    ## `fullCapture` on the floor would be invisible without this case.
    resetBuildActionRegistry()
    let act = fullTool.run(output = "build/out.bin")
    check act.dependencyPolicy.captureBreadth == mcbFullCapture

  test "a tool that declares nothing asks for everything":
    ## THE ZERO VALUE IS THE WIDEST ANSWER, which is the direction that has to
    ## hold: a tool package that has never heard of DA-6 must not have been
    ## narrowed by DA-6 existing.
    resetBuildActionRegistry()
    let act = silentTool.run(output = "build/out.bin")
    check act.dependencyPolicy.captureBreadth == mcbFullCapture

suite "DA-6 captureNonDeterminism now means the ambient reads, and only those":

  test "captureNonDeterminism = false excludes the ambient reads":
    ## The field DA-5 said could become honourable "with its scope shrunk to the
    ## part that was ever safe". This is that scope: `false` drops
    ## `ecAmbientReads` and nothing else — the env reads that key the action and
    ## the entropy that gates publication are not at this flag's mercy any more,
    ## and the engine's `static:` chokepoint is what makes that true by
    ## construction rather than by this mapping being careful.
    resetBuildActionRegistry()
    let act = legacyFalseTool.run(output = "build/out.bin")
    check act.dependencyPolicy.captureBreadth == mcbOmitAmbientReads

  test "captureNonDeterminism = true keeps them":
    ## The polarity control. The field is named for a CAPTURE, so `true` has to
    ## mean "capture them" — a bool whose `true` value dropped records is how the
    ## previous generation of this field came to carry a false comment that
    ## nobody could refuse.
    resetBuildActionRegistry()
    let act = legacyTrueTool.run(output = "build/out.bin")
    check act.dependencyPolicy.captureBreadth == mcbFullCapture

  test "the two polarities are distinguishable":
    ## Without this, a parser that ignored the flag entirely would pass one of
    ## the two cases above and the other only by luck of which default it hit.
    resetBuildActionRegistry()
    let a = legacyFalseTool.run(output = "build/a.bin")
    resetBuildActionRegistry()
    let b = legacyTrueTool.run(output = "build/b.bin")
    check a.dependencyPolicy.captureBreadth !=
      b.dependencyPolicy.captureBreadth

suite "DA-6 the parser refuses what cannot be honoured":

  test "a legal declaration compiles — the positive control":
    ## FIRST, because every refusal below is worthless if this recipe text does
    ## not compile for some unrelated reason. Same source shape, legal clause.
    let probe = checkRecipeSource(recipeWith("captureBreadth = fullCapture"),
      "da6-positive")
    if not probe.ok:
      echo "the POSITIVE control did not compile, so the refusals below prove ",
        "nothing about the clause under test:\n", probe.output
    check probe.ok

  test "captureIpc is refused by name, and the diagnostic says why":
    ## `captureIpc` was inert before DA-5 and is STRUCTURALLY inert after it:
    ## `categoryOf` answers `none` for `mrIpcConnect`, so there is no
    ## granularity at which either value of the switch could be honoured. A
    ## switch that can never be honoured is worse than no switch — its author
    ## believes they changed something — so it is an error and the error has to
    ## carry the reason and the replacement.
    let probe = checkRecipeSource(recipeWith("captureIpc = true"),
      "da6-ipc")
    check not probe.ok
    check "captureIpc has been RETIRED" in probe.output
    # The reason, so a reader is not left to take the refusal on faith…
    check "not gate-able" in probe.output
    check "mergeFragments" in probe.output
    # …and what to write instead, so the refusal is actionable.
    check "captureBreadth" in probe.output

  test "captureIpc = false is refused too, not just the widening":
    ## Both polarities, because the author of `captureIpc = false` believes they
    ## NARROWED something and is equally wrong. A parser that refused only the
    ## `true` case would leave the reading that matters most for a cache —
    ## "I turned IPC observation off" — silently accepted.
    let probe = checkRecipeSource(recipeWith("captureIpc = false"),
      "da6-ipc-false")
    check not probe.ok
    check "captureIpc has been RETIRED" in probe.output

  test "an unrecognised breadth word is refused, not inherited":
    ## `dependencyPolicy`'s own unknown-POLICY-name case falls back to the
    ## inherited value (it predates this), and that reading is not available
    ## here for the reason `parseNonDeterminismDecl` gives for refusing it: a
    ## misspelt narrowing that silently inherited the enclosing scope's value
    ## reads to its author as "the narrowing took", and the failure it produces
    ## is on the axis where being wrong publishes a cache entry from evidence
    ## nobody checked.
    let probe = checkRecipeSource(
      recipeWith("captureBreadth = readsOnlyPlease"), "da6-bogus")
    check not probe.ok
    check "captureBreadth expects fullCapture or omitAmbientReads" in
      probe.output
    # And the refusal explains why the vocabulary is only two words, naming the
    # consumers that make the other 254 subsets unsafe.
    check "cacheEnvInputs" in probe.output
    check "applyEntropyBlessingPolicy" in probe.output

  test "the `package` door refuses the same two things":
    ## THE DOOR THE TOOL PACKAGES ACTUALLY USE. `package … : cli:` is parsed by
    ## `parseCommandDependencyPolicy` and `defineCliInterface` by
    ## `parseInterfaceDependencyPolicy` — two procs, two copies of every clause,
    ## and a clause added to one and not the other is silently ignored in the
    ## other. That is not hypothetical on this surface: it is exactly how the
    ## engine's interest request came to differ between its two hosting paths.
    ## The positive control comes first here too.
    let positive = checkRecipeSource(
      packageRecipeWith("captureBreadth = omitAmbientReads"), "da6-pkg-ok")
    if not positive.ok:
      echo "the `package`-door POSITIVE control did not compile:\n",
        positive.output
    check positive.ok
    let ipc = checkRecipeSource(packageRecipeWith("captureIpc = true"),
      "da6-pkg-ipc")
    check not ipc.ok
    check "captureIpc has been RETIRED" in ipc.output
    let bogus = checkRecipeSource(
      packageRecipeWith("captureBreadth = readsOnlyPlease"), "da6-pkg-bogus")
    check not bogus.ok
    check "captureBreadth expects fullCapture or omitAmbientReads" in
      bogus.output

suite "DA-6 the declaration survives the transport to the engine":
  ## THE HOP THAT MADE THE WHOLE DECLARATION A NO-OP, found by review and fixed
  ## with payload version 27.
  ##
  ## A declaration is only worth the comment above it if it reaches
  ## `monitorInterest`, and between the DSL and the engine sits ONE codec that
  ## every provider graph node goes through: `encodeBuildActionPayload` /
  ## `decodeBuildActionPayload`. `actionPayload` encodes each `gnkAction` node,
  ## and `repro_cli_support`'s `lowerItem` RE-ENCODES through the same codec
  ## immediately before `lowerGraphAction` decodes it and hands the policy to
  ## `lowerDependencyPolicy`. A field the codec does not carry is therefore reset
  ## to its zero value on the way in, unconditionally, on the shipping path.
  ##
  ## That is exactly what happened: `captureBreadth` was added to the type, to
  ## both DSL doors, to the lowered-graph cache (v10) and to a compile-time
  ## chokepoint, and NOT to this codec — so every tool package's declaration was
  ## discarded before the engine could read it and `monitorInterest` answered
  ## `FullInterest` for every action. The lowered-graph cache round-trip passed
  ## the whole time, because it faithfully round-tripped a value that had already
  ## been flattened to the default.
  ##
  ## The positive control is what makes these cases non-vacuous: a sibling field
  ## the codec DOES carry (`suppressMonitorShimSeed`, v25) must survive the same
  ## round trip. Without it a codec that dropped the entire policy would satisfy
  ## an assertion on the default value.

  test "a declared narrowing survives the payload round trip":
    for declared in [mcbFullCapture, mcbOmitAmbientReads]:
      let action = BuildActionDef(
        id: "da6-payload-" & $declared,
        dependencyPolicy: automaticMonitorPolicy(captureBreadth = declared))
      let back = decodeBuildActionPayload(encodeBuildActionPayload(action))
      if back.dependencyPolicy.captureBreadth != declared:
        echo "a tool package declaring `", declared, "` reached the engine as `",
          back.dependencyPolicy.captureBreadth, "`. The declaration is dropped ",
          "on the DSL->engine hop, so monitorInterest reads the zero value for ",
          "every action and no tool package's narrowing has any effect."
      check back.dependencyPolicy.captureBreadth == declared

  test "the codec carries it ALONGSIDE the field that already round-tripped":
    ## The anti-vacuity control. `suppressMonitorShimSeed` is v25 and was always
    ## carried; if it survives and `captureBreadth` does not, the loss is this
    ## field's and not a broken fixture.
    let action = BuildActionDef(
      id: "da6-payload-control",
      dependencyPolicy: makeDepfilePolicy("da6.d",
        captureBreadth = mcbOmitAmbientReads,
        suppressMonitorShimSeed = true))
    let back = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check back.dependencyPolicy.suppressMonitorShimSeed
    check back.dependencyPolicy.captureBreadth == mcbOmitAmbientReads

  test "a pre-declaration payload reads as FULL capture, not as a narrowing":
    ## THE FAIL-SAFE DIRECTION OF THE VERSION GATE. A v26-or-earlier payload
    ## carries no breadth byte, and the field must come back `mcbFullCapture`:
    ## such a payload was written before any tool could declare a narrowing, so
    ## reading a missing byte as a narrowing would narrow a capture on nobody's
    ## decision — and a narrowed capture trusted as a full one is the false
    ## `mcComplete` this whole vocabulary exists to make inexpressible.
    let action = BuildActionDef(
      id: "da6-payload-legacy",
      dependencyPolicy: automaticMonitorPolicy(
        captureBreadth = mcbOmitAmbientReads))
    let legacy = encodeBuildActionPayloadAtVersion(action, 26'u16)
    let back = decodeBuildActionPayload(legacy)
    check back.dependencyPolicy.captureBreadth == mcbFullCapture

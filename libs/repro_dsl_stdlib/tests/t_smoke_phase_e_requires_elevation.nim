## Windows-System-Resources Phase E — `buildAction(..., requiresElevation
## = true)` plumbing through the DSL types and the BuildActionDef
## codec.
##
## The action edge attribute marks a build-graph edge whose execution
## must cross the privileged-operation broker. The DSL surface is
## ``buildAction(id, inlineExecCall(argv), ..., requiresElevation =
## true)`` — `inlineExecCall` itself still returns a `PublicCliCall`
## (the engine's `reprobuild.builtin.exec` lowering recognizes it);
## the `requiresElevation` flag lives on the EDGE (the
## `BuildActionDef`), not on the call.
##
## What this test pins:
##
##   * the new field on `BuildActionDef` is default-`false`;
##   * `buildAction(...)` exposes the optional parameter (back-compat
##     for every call site that omits it);
##   * setting `requiresElevation = true` flows the flag through onto
##     the emitted action;
##   * the codec round-trips the flag (v19+);
##   * combining `inlineExecCall(...)` and `requiresElevation = true`
##     produces an action whose `call` still names the
##     `reprobuild.builtin.exec` builtin AND whose edge attribute
##     records the elevation requirement.

import std/[strutils, unittest]

import repro_project_dsl

suite "Phase E — requiresElevation on the build-graph edge":

  test "BuildActionDef.requiresElevation defaults to false":
    # The new field on the existing record type must default to
    # ``false`` so every pre-Phase-E `BuildActionDef{...}` literal in
    # the codebase keeps producing an edge with no elevation
    # requirement — zero behavior change for the legacy corpus.
    let action = BuildActionDef(id: "legacy-no-flag")
    check action.requiresElevation == false

  test "buildAction(...) without requiresElevation defaults to false":
    # The constructor's default value MUST be ``false`` so existing
    # call sites (autotools_package, meson_package, cmake_package,
    # every from-source convention) are byte-identical to today.
    resetBuildActionRegistry()
    let action = buildAction("legacy-default",
      inlineExecCall(@["sh", "-c", "echo hi"]))
    check action.requiresElevation == false

  test "buildAction(..., requiresElevation = true) sets the flag":
    # The new parameter must accept the explicit ``true`` and stamp
    # the emitted ``BuildActionDef`` accordingly.
    resetBuildActionRegistry()
    let action = buildAction("elevated-edge",
      inlineExecCall(@["C:\\actions-runner\\config.cmd",
        "--unattended", "--token",
        "@FILE:C:\\actions-runner-tokens\\mcl.token"]),
      requiresElevation = true)
    check action.requiresElevation == true

  test "the call still names reprobuild.builtin.exec":
    # The elevation flag does NOT swap the call shape — the action's
    # `call.packageName` / `executableName` is unchanged so
    # ``lowerGraphAction`` still recognises the inline-exec builtin
    # branch and routes through the same lowering path. Phase E adds
    # a NEW branch on the flag inside that path, not a parallel
    # lowering chain.
    resetBuildActionRegistry()
    let elevated = buildAction("elevated-pin",
      inlineExecCall(@["C:\\bin\\x.exe"]),
      requiresElevation = true)
    check elevated.call.packageName == "reprobuild.builtin"
    check elevated.call.executableName == "exec"

  test "BuildActionDef payload codec round-trips requiresElevation = true":
    # Phase E v19: the new sentinel byte must survive an encode /
    # decode cycle. Pre-Phase-E payloads (v18-and-earlier) decode
    # with the flag at ``false`` — see the ``older v16 payload
    # decodes with empty toolIdentityRefs`` test in
    # ``t_engine_typed_output_payload_codec_round_trip`` for the
    # legacy decode path; here we pin the forward direction.
    let action = BuildActionDef(
      id: "elev-codec",
      call: publicCliCall("reprobuild.builtin", "exec", "",
        "reprobuild.builtin.exec", @[
          cliArgSeq("argv", @["sh", "-c", "echo hi"], cpkPositional, 0)
        ]),
      cacheable: true,
      commandStatsId: "elev-codec",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      requiresElevation: true)
    let bytes = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(bytes)
    check decoded.id == "elev-codec"
    check decoded.requiresElevation == true

  test "BuildActionDef payload codec round-trips requiresElevation = false":
    # The default value's round-trip is the back-compat insurance —
    # encoding/decoding an inert action MUST keep the flag at
    # ``false``.
    let action = BuildActionDef(
      id: "elev-codec-false",
      call: publicCliCall("reprobuild.builtin", "exec", "",
        "reprobuild.builtin.exec", @[
          cliArgSeq("argv", @["sh", "-c", "echo hi"], cpkPositional, 0)
        ]),
      cacheable: true,
      commandStatsId: "elev-codec-false",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      requiresElevation: false)
    let bytes = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(bytes)
    check decoded.requiresElevation == false

  test "inlineExecCall + requiresElevation: every load-bearing field survives":
    # The spec's example call shape: an elevated `inlineExecCall(...)`
    # carrying argv + toolIdentityRefs + inputs/outputs +
    # requiresElevation. Pin that every field flows through to the
    # `BuildActionDef`.
    resetBuildActionRegistry()
    let action = buildAction("phaseE-spec-example",
      call = inlineExecCall(@["config.cmd", "--unattended", "--replace",
        "--url", "https://github.com/metacraft-labs",
        "--token", "@FILE:C:\\actions-runner-tokens\\mcl.token",
        "--name", "windows-runner-001"]),
      inputs = @["C:\\actions-runner-tokens\\mcl.token"],
      outputs = @["C:\\actions-runner\\.runner"],
      toolIdentityRefs = @["C:\\actions-runner\\config.cmd"],
      requiresElevation = true)
    check action.id == "phaseE-spec-example"
    check action.requiresElevation == true
    check action.inputs == @["C:\\actions-runner-tokens\\mcl.token"]
    check action.outputs == @["C:\\actions-runner\\.runner"]
    check action.toolIdentityRefs == @["C:\\actions-runner\\config.cmd"]
    # The literal `@FILE:` token rides through unchanged — the spec
    # explicitly stores it in the plan; the @FILE: expander runs at
    # the moment of execution, not at lowering / encoding.
    var sawToken = false
    for arg in action.call.arguments:
      if arg.encodedValue.contains("@FILE:C:\\actions-runner-tokens\\mcl.token"):
        sawToken = true
    check sawToken

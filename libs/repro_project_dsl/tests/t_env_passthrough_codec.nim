## An edge's environment passthrough names (`BuildActionDef.envPassthrough`)
## survive registration and the build-action payload codec.
##
## The names reach the engine's `BuildAction.envPassthrough`, which keys each
## by NAME and drops its observed reads from the value-keyed environment set
## (reprobuild-pm `spec/Filesystem-Policy-And-Observed-Inputs.md`
## §"Declared And Passthrough Variables"). A codec that dropped them would
## make every warm lowering key those reads by value again, so the first
## build in each new shell would miss (`nim.c` and its temp-directory names).
##
## No mocks: the real registry and the real v36 codec.

import std/unittest

import repro_project_dsl

suite "action environment passthrough":
  setup:
    resetBuildActionRegistry()

  test "registration appends in order, deduplicated, empty names skipped":
    discard buildAction(
      id = "nim-compile",
      call = inlineExecCall(@["nim", "c"]))
    appendRegisteredActionEnvPassthrough("nim-compile", ["TMPDIR", "TMP"])
    appendRegisteredActionEnvPassthrough("nim-compile", ["TMP", "", "TEMP"])
    let action = registeredBuildActions()[0]
    check action.envPassthrough == @["TMPDIR", "TMP", "TEMP"]
    # Passthrough says nothing about the declared environment.
    check action.env.len == 0

  test "the handle form updates the registry entry and the caller's copy":
    var action = buildAction(
      id = "nim-compile",
      call = inlineExecCall(@["nim", "c"]))
    appendRegisteredActionEnvPassthrough(action, ["TMPDIR", "TEMPDIR"])
    appendRegisteredActionEnvPassthrough(action, ["TEMPDIR"])
    check action.envPassthrough == @["TMPDIR", "TEMPDIR"]
    check registeredBuildActions()[0].envPassthrough == action.envPassthrough

  test "a repeated id names the entry registered last":
    # A typed call repeated with the same arguments registers a second
    # entry under one id; the constructor that just made the call means the
    # second one.
    discard buildAction(id = "dup", call = inlineExecCall(@["nim", "c"]))
    discard buildAction(id = "dup", call = inlineExecCall(@["nim", "c"]))
    appendRegisteredActionEnvPassthrough("dup", ["TMPDIR"])
    let registered = registeredBuildActions()
    check registered.len == 2
    check registered[0].envPassthrough.len == 0
    check registered[1].envPassthrough == @["TMPDIR"]

  test "PATH is refused: its class belongs to the tool references":
    discard buildAction(id = "p", call = inlineExecCall(@["sh"]))
    expect ValueError:
      appendRegisteredActionEnvPassthrough("p", ["TMPDIR", "Path"])
    # Refused before anything was recorded.
    check registeredBuildActions()[0].envPassthrough.len == 0

  test "the payload round-trips the names; a v35 payload carries none":
    let action = BuildActionDef(
      id: "nim-compile",
      call: inlineExecCall(@["nim", "c"]),
      env: @[("TMPDIR", "/declared")],
      envPassthrough: @["TMPDIR", "TMP", "TEMP", "TEMPDIR"])
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.envPassthrough == @["TMPDIR", "TMP", "TEMP", "TEMPDIR"]
    # A name both declared and passthrough keeps both halves.
    check decoded.env == @[("TMPDIR", "/declared")]
    check buildActionPayloadVersion(encodeBuildActionPayload(action)) == 36'u16
    let v35 = decodeBuildActionPayload(
      encodeBuildActionPayloadAtVersion(action, 35'u16))
    check v35.envPassthrough.len == 0
    check v35.env == @[("TMPDIR", "/declared")]
    # The names are part of the payload bytes the lowering keys the edge on
    # (`node.payload` is in every lowered fingerprint text).
    check encodeBuildActionPayload(action) != encodeBuildActionPayload(
      BuildActionDef(id: action.id, call: action.call, env: action.env))

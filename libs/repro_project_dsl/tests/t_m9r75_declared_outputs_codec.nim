## M9.R.75 verification — R6/R7 write-scope declaration round-trips
## losslessly through ``encodeBuildActionPayload`` /
## ``decodeBuildActionPayload`` (v22). Older v21 payloads decode with
## both seqs empty so the legacy corpus stays byte-identical.
##
## Spec cite: reprobuild-specs Filesystem-Policy-And-Observed-Inputs.md
## §"Double Writes" (lines 246-262, R7) and §"Source Rewrites"
## (lines 264-278, R6).

import std/[unittest]

import repro_project_dsl

suite "t_m9r75_declared_outputs_codec":

  test "round-trip empty declaredOutputs + readOnlyRoots (legacy default)":
    ## Legacy actions that don't opt in must round-trip with both seqs
    ## empty so the engine's R6/R7 enforcement passes no-op for them.
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "legacy",
      call: call)
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.declaredOutputs.len == 0
    check decoded.readOnlyRoots.len == 0

  test "round-trip single declaredOutputs entry":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "single-out",
      call: call,
      declaredOutputs: @["/tmp/build/foo"])
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.declaredOutputs == @["/tmp/build/foo"]
    check decoded.readOnlyRoots.len == 0

  test "round-trip multiple declaredOutputs entries preserves order":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "multi-out",
      call: call,
      declaredOutputs: @[
        "/tmp/build/lib",
        "/tmp/build/bin",
        "/tmp/install/usr"])
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.declaredOutputs == @[
      "/tmp/build/lib",
      "/tmp/build/bin",
      "/tmp/install/usr"]

  test "round-trip readOnlyRoots preserves entries + order":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "ro-roots",
      call: call,
      readOnlyRoots: @[
        "/tmp/src/upstream",
        "/tmp/src/patched"])
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.readOnlyRoots == @[
      "/tmp/src/upstream",
      "/tmp/src/patched"]

  test "round-trip both fields populated simultaneously":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "both",
      call: call,
      declaredOutputs: @["/tmp/build/mesa"],
      readOnlyRoots: @["/tmp/src/mesa"])
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.declaredOutputs == @["/tmp/build/mesa"]
    check decoded.readOnlyRoots == @["/tmp/src/mesa"]

  test "buildAction proc defaults to empty seqs":
    ## Callers who don't pass the new params get empty seqs — the
    ## guarantee that every pre-M9.R.75 recipe survives the codec bump
    ## unchanged.
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = buildAction(
      id = "no-opt-in",
      call = call)
    check action.declaredOutputs.len == 0
    check action.readOnlyRoots.len == 0

  test "buildAction proc accepts explicit write-scope declarations":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = buildAction(
      id = "opt-in",
      call = call,
      declaredOutputs = ["/tmp/build/x"],
      readOnlyRoots = ["/tmp/src/x"])
    check action.declaredOutputs == @["/tmp/build/x"]
    check action.readOnlyRoots == @["/tmp/src/x"]

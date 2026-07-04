## M9.R.74 verification — canonical execution root (R2) declaration
## round-trips losslessly through ``encodeBuildActionPayload`` /
## ``decodeBuildActionPayload`` (v21). Older v20 payloads decode with
## the legacy default ``cwdKind = acwdRecipeRoot`` +
## ``cwdCustomPath = ""`` so the legacy corpus stays byte-identical.
##
## Pure codec test — no provider mode required. Builds synthetic
## ``BuildActionDef`` values in-line, encodes each, decodes it back,
## and asserts on every M9.R.74 field.

import std/[unittest]

import repro_project_dsl

suite "t_m9r74_action_cwd_kind_codec":

  test "round-trip acwdRecipeRoot with empty custom path":
    ## The enum's zero value + empty custom path is the legacy default;
    ## a v21 payload must still decode to the same values so downstream
    ## consumers can't tell the payload from a legacy v20 one.
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "action-recipe-root",
      call: call,
      cwdKind: acwdRecipeRoot,
      cwdCustomPath: "")
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.cwdKind == acwdRecipeRoot
    check decoded.cwdCustomPath == ""

  test "round-trip acwdBuild with resolved relative path":
    ## Convention emitters (``autotools_package`` / ``meson_package`` /
    ## ``cmake_package``) pass ``acwdBuild`` + the resolved build-dir
    ## path; the codec must preserve both.
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "action-build",
      call: call,
      cwdKind: acwdBuild,
      cwdCustomPath: "build")
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.cwdKind == acwdBuild
    check decoded.cwdCustomPath == "build"

  test "round-trip acwdSource with absolute path":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "action-source",
      call: call,
      cwdKind: acwdSource,
      cwdCustomPath: "/abs/path/to/src")
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.cwdKind == acwdSource
    check decoded.cwdCustomPath == "/abs/path/to/src"

  test "round-trip acwdInstall preserved":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "action-install",
      call: call,
      cwdKind: acwdInstall,
      cwdCustomPath: "build/out")
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.cwdKind == acwdInstall
    check decoded.cwdCustomPath == "build/out"

  test "round-trip acwdCustom preserves both fields":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = BuildActionDef(
      id: "action-custom",
      call: call,
      cwdKind: acwdCustom,
      cwdCustomPath: "custom/subdir")
    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)
    check decoded.cwdKind == acwdCustom
    check decoded.cwdCustomPath == "custom/subdir"

  test "buildAction proc defaults to acwdRecipeRoot + empty custom path":
    ## Callers who don't pass ``cwdKind`` / ``cwdCustomPath`` get the
    ## legacy default — the guarantee that every pre-M9.R.74 recipe
    ## survives the codec bump unchanged.
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = buildAction(
      id = "legacy-action",
      call = call)
    check action.cwdKind == acwdRecipeRoot
    check action.cwdCustomPath == ""

  test "buildAction proc accepts explicit cwdKind + path":
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[])
    let action = buildAction(
      id = "explicit-action",
      call = call,
      cwdKind = acwdBuild,
      cwdCustomPath = "build")
    check action.cwdKind == acwdBuild
    check action.cwdCustomPath == "build"

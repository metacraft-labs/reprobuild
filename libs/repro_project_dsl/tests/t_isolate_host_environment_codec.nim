## The action payload carries `isolateHostEnvironment` (payload codec v40).
##
## An isolated action is launched from its declared environment alone. The
## flag reaches the engine only through the payload the provider writes and
## the CLI decodes, so the payload must round-trip it, an older payload must
## decode as not isolated (how every action was launched before the field),
## the flag must change the payload's bytes (the lowering keys an edge on
## them), and an isolated action registered through `buildAction` must not
## pick up the package-default variables a package's shell edges get.
##
## Falsifying mutation (applied, observed to fail, reverted): decoding the
## v40 byte as always false fails the round trip.
##
## No mocks: the production codec and constructor.

import std/unittest

import repro_project_dsl

suite "action payload isolateHostEnvironment":
  setup:
    resetBuildActionRegistry()

  test "the payload round-trips the flag; a v39 payload decodes as not " &
      "isolated":
    let isolated = BuildActionDef(
      id: "cargo.rustc/a@0.1.0-0123456789abcdef",
      call: inlineExecCall(@["rustc", "--crate-name", "a"]),
      env: @[("PATH", "/toolchain/bin"), ("CARGO_PKG_NAME", "a")],
      isolateHostEnvironment: true)
    let bytes = encodeBuildActionPayload(isolated)
    check buildActionPayloadVersion(bytes) == BuildActionPayloadVersion
    check BuildActionPayloadVersion >= 40'u16
    let decoded = decodeBuildActionPayload(bytes)
    check decoded.isolateHostEnvironment
    check decoded.env == isolated.env
    var open = isolated
    open.isolateHostEnvironment = false
    check not decodeBuildActionPayload(
      encodeBuildActionPayload(open)).isolateHostEnvironment
    check encodeBuildActionPayload(open) != bytes
    let v39 = decodeBuildActionPayload(
      encodeBuildActionPayloadAtVersion(isolated, 39'u16))
    check not v39.isolateHostEnvironment
    check v39.env == isolated.env

  test "buildAction records the flag and the declared environment only":
    let def = buildAction(
      id = "cargo.rustc/a@0.1.0-0123456789abcdef",
      call = inlineExecCall(@["rustc"]),
      env = @[("CARGO_PKG_NAME", "a")],
      isolateHostEnvironment = true)
    check def.isolateHostEnvironment
    check def.env == @[("CARGO_PKG_NAME", "a")]
    check registeredBuildActions()[0].isolateHostEnvironment

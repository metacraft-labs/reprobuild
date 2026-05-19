## Smoke test: does the Configurable module compile and run a single
## evalConfig block end-to-end? Used during M58 implementation to
## catch import/syntax breakage early; the real gates live under
## `tests/integration/` and `tests/e2e/`.

import std/[unittest]
import repro_dsl_stdlib/configurables

suite "Configurable smoke":

  test "evalConfig + configurable + read":
    let ctx = evalConfig:
      let port = configurable 8080
      port.override 9000
    check ctx.read(Configurable[int](id: ConstructionId(0))) == 9000

  test "two evalConfig blocks are independent":
    let staging = evalConfig:
      let port = configurable 8080
      port.override 4
    let production = evalConfig:
      let port = configurable 8080
      port.override 32
    check staging.read(Configurable[int](id: ConstructionId(0))) == 4
    check production.read(Configurable[int](id: ConstructionId(0))) == 32

  test "string concatenation works":
    var urlHandle: Configurable[string]
    let ctx = evalConfig:
      let host = configurable "localhost"
      let port = configurable 8080
      let url = "http://" & host & ":" & $port
      urlHandle = url
    check ctx.read(urlHandle) == "http://localhost:8080"

## Shared-Development-Services L4 — the declared ``identity`` and
## ``scope`` reach the lowered ``DslServiceDef`` and survive the
## ``gnkService`` payload codec.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The subject is the real ``package`` macro expanding real recipes in
## this module and the real codec round-tripping their records.
##
## WHICH DISCRIMINATOR THIS FILE RESTS ON. Not an exit code: this file
## reads ``DslServiceDef.identity`` and ``DslServiceDef.scope``, fields
## that DO NOT EXIST at the base commit, so at the base the test module
## does not compile at all and the measurement is the compiler's
## ``undeclared field: 'identity'``. That is stated rather than implied
## because the campaign's rule is to say which case each test is in; the
## behavioural before/after for the same feature is in
## ``t_dsl_service_identity_scope_surface.nim``, where the base COMPILES
## every malformed spelling and the exit code genuinely moves.
##
## Governing spec text — ``Shared-Development-Services.md`` §4.1 / §4.2;
## the two defaults are "``project`` … the default, and today's only
## behaviour" and "``derived`` — the default".

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

package l4RecordPkg:
  executable l4Bin:
    build:
      output("bin/l4")

  service stableWide:
    ## Named `stableWide` and not `declared`, which is where the first
    ## draft of this fixture went. L3's lift emits a top-level accessor
    ## `proc <serviceName>*(pkg: <Title>Package)` per export, so a
    ## service named `declared` puts a `declared` into this MODULE's
    ## scope and shadows `system.declared` -- and `unittest`'s own
    ## `check` expands to a `declared(...)` call, so every `check` in the
    ## file then failed to compile with `cannot generate code for:
    ## mDeclared`. Recorded here rather than worked around silently: it
    ## is the same name-collision family L3's `l3CheckExportNames`
    ## already refuses five spellings of, and a sixth (a Nim MAGIC that
    ## is not a name the lift itself emits) is not L4's milestone to add.
    executable l4Bin
    args "--serve"
    identity stable "com.example.l4.stable"
    scope workspace

  service defaulted:
    ## No `identity`, no `scope`. §4's two defaults, which are also
    ## pre-L4 behaviour, so this service's record must be what the DSL
    ## recorded for it before this milestone PLUS the ground state.
    executable l4Bin

  service explicitDefaults:
    ## The author writing the defaults out loud. Resolves to the same
    ## values as `defaulted` — the difference is only that these were
    ## chosen, and §4.2's author rule makes the choice worth writing.
    executable l4Bin
    identity derived
    scope project

  service machineWide:
    executable l4Bin
    identity stable "com.example.l4.machine"
    scope system

  service perUser:
    executable l4Bin
    scope user

proc serviceNamed(name: string): DslServiceDef =
  for svc in registeredServices("l4RecordPkg"):
    if svc.serviceName == name:
      return svc
  raise newException(ValueError, "no service named " & name)

suite "L4 — the declared identity and scope reach the record":

  test "`identity stable \"<id>\"` lowers to sikStable plus the id":
    let svc = serviceNamed("stableWide")
    check svc.identity.kind == sikStable
    check svc.identity.stableId == "com.example.l4.stable"

  test "`scope workspace` lowers to sscWorkspace":
    check serviceNamed("stableWide").scope == sscWorkspace

  test "all four scopes are reachable from a recipe":
    # Derived from the enum rather than listed, so a fifth scope added to
    # `ServiceScope` without a recipe spelling fails here.
    var seen: seq[ServiceScope] = @[]
    for name in ["stableWide", "explicitDefaults", "machineWide", "perUser"]:
      let scope = serviceNamed(name).scope
      if scope notin seen:
        seen.add(scope)
    check seen.len == int(high(ServiceScope)) + 1

  test "`identity derived` records NO id, even if one were in scope":
    let svc = serviceNamed("explicitDefaults")
    check svc.identity.kind == sikDerived
    check svc.identity.stableId == ""

suite "L4 — the defaults are the ground state, not an `unset`":

  test "a body with neither setter carries derived + project":
    let svc = serviceNamed("defaulted")
    check svc.identity.kind == sikDerived
    check svc.identity.stableId == ""
    check svc.scope == sscProject

  test "and that is byte-identical to writing them out":
    # §4.1 and §4.2 each name a default, so there is no third state for a
    # record to be in. If this pair ever diverged, "the author said
    # nothing" and "the author said `derived`" would be different
    # instances of the same service.
    let implicit = serviceNamed("defaulted")
    let explicitly = serviceNamed("explicitDefaults")
    check implicit.identity == explicitly.identity
    check implicit.scope == explicitly.scope

  test "the ground state is enum ordinal zero, which is what v1 decodes":
    # The payload compatibility below depends on this and nothing else.
    check ord(sikDerived) == 0
    check ord(sscProject) == 0

  test "one setter alone leaves the other at its default":
    let svc = serviceNamed("perUser")
    check svc.scope == sscUser
    check svc.identity.kind == sikDerived

  test "a legacy positional registration carries the defaults too":
    # `registerService` is the M5/M9.C entry point and gained no
    # parameters here. A caller that predates L4 must still produce a
    # record that resolves, and it must resolve to today's behaviour.
    resetDslPortServiceState()
    registerService("l4LegacyPkg", "legacy", "someBin", @["--x"], "")
    let svcs = registeredServices("l4LegacyPkg")
    check svcs.len == 1
    check svcs[0].identity.kind == sikDerived
    check svcs[0].scope == sscProject

suite "L4 — identity and scope survive the gnkService payload codec":

  test "a stable identity and a wide scope round-trip":
    var def = DslServiceDef(
      packageName: "l4CodecPkg", serviceName: "sso",
      identity: ServiceIdentityDef(kind: sikStable,
        stableId: "com.example.l4.codec"),
      scope: sscSystem)
    let decoded = decodeServicePayload(encodeServicePayload(def))
    check decoded.identity.kind == sikStable
    check decoded.identity.stableId == "com.example.l4.codec"
    check decoded.scope == sscSystem

  test "every scope round-trips, derived from the enum":
    for scope in ServiceScope:
      var def = DslServiceDef(packageName: "p", serviceName: "s",
        scope: scope)
      check decodeServicePayload(encodeServicePayload(def)).scope == scope

  test "a v1 payload decodes to the DEFAULTS, not to a failure":
    # The v1 body is the current encoder's output with the trailing
    # identity block removed and the header rewritten to v1 -- built from
    # the real encoder rather than hand-typed, so it cannot drift from
    # what v1 actually was. The trailing block is one kind byte, one
    # length-prefixed empty string (4 bytes) and one scope byte = 6.
    var def = DslServiceDef(
      packageName: "l4CodecPkg", serviceName: "legacy",
      executableRef: "bin", args: @["--x"],
      identity: ServiceIdentityDef(kind: sikDerived), scope: sscProject)
    var v2 = encodeServicePayload(def)
    let tailLen = 6
    var v1 = v2[0 ..< v2.len - tailLen]
    # version u16 at offset 4, little-endian; body length u32 at 6.
    v1[4] = 1'u8
    v1[5] = 0'u8
    let bodyLen = uint32(v1.len - 10)
    v1[6] = byte(bodyLen and 0xFF'u32)
    v1[7] = byte((bodyLen shr 8) and 0xFF'u32)
    v1[8] = byte((bodyLen shr 16) and 0xFF'u32)
    v1[9] = byte((bodyLen shr 24) and 0xFF'u32)
    let decoded = decodeServicePayload(v1)
    check decoded.serviceName == "legacy"
    check decoded.args == @["--x"]
    check decoded.identity.kind == sikDerived
    check decoded.identity.stableId == ""
    check decoded.scope == sscProject

  test "a FUTURE version is still refused rather than misread":
    # The version check widened from `!= current` to a range so v1 could
    # be read. The property the envelope exists for has to survive that.
    var v2 = encodeServicePayload(DslServiceDef(
      packageName: "p", serviceName: "s"))
    var v3 = v2
    v3[4] = 3'u8
    expect BuildActionPayloadError:
      discard decodeServicePayload(v3)
    var v0 = v2
    v0[4] = 0'u8
    expect BuildActionPayloadError:
      discard decodeServicePayload(v0)

  test "an out-of-range scope byte is refused, not cast":
    var bytes = encodeServicePayload(DslServiceDef(
      packageName: "p", serviceName: "s"))
    bytes[^1] = 9'u8
    expect BuildActionPayloadError:
      discard decodeServicePayload(bytes)

  test "an out-of-range identity kind is refused, not cast":
    var bytes = encodeServicePayload(DslServiceDef(
      packageName: "p", serviceName: "s"))
    # kind byte, then a 4-byte empty-string length, then the scope byte.
    bytes[^6] = 9'u8
    expect BuildActionPayloadError:
      discard decodeServicePayload(bytes)

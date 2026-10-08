## Shared-Development-Services L3 — an export cannot be given a name the
## LIFT ITSELF emits at module scope, and the refusal lands on the
## author's own declaration.
##
## WHY THIS SUITE EXISTS. `l3CheckExportNames`' own doc comment says it
## refuses "the name clashes the emission cannot survive, naming the
## clash rather than letting Nim report a redefinition in generated
## code". It reserved the package's `const <packageValueIdent>` and the
## export names against each other, and nothing else — so `service
## liftedExports:` collided with the emitted
## `proc liftedExports*(pkg: <Title>Package)` and failed with
## `Error: overloaded 'liftedExports' leads to ambiguous calls`, anchored
## in GENERATED code: exactly the outcome that proc exists to prevent.
## Found by L3's review agent, reported not fixed, and fixed here.
##
## The reservation is the full emitted set, not the one name that was
## reported: `l3EmittedModuleScopeNames` derives it from the same consts
## and namers the emission interpolates, so each case below pins one
## MEMBER of that set and the next emitted name added cannot reopen the
## hole for the member it adds.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case writes one real recipe to a real filesystem and compiles it
## with the real `nim` this repo is built with; the text asserted on is
## the compiler's real output. See `service_block_compile_probe.nim` for
## why the in-process `compiles` spelling cannot be used for a `package`
## block (short version: measured, it answers *false* for every one,
## well-formed or not, so a refusal and its control would both be
## vacuous; filed as `reprobuild-pm/issues/2026-10-08-package-macro-
## refusal-gates-are-vacuous-under-not-compiles.md`).
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, AND IT IS NOT THE SAME ONE IN
## EVERY CASE. Measured with the reservation absent and this file
## present — the first five at `68abb6308`, the sixth at `60bdcbbbb`,
## which is the commit that introduced the other five — on the same six
## fixtures:
##
## * `liftedExports` as a service and as an activity — exit 1, but with
##   `Error: overloaded 'liftedExports' leads to ambiguous calls` and
##   `redefinition of 'liftedExports'` reported at `(25, 6)` / `(23, 6)`
##   of a SEVENTEEN-LINE recipe and with no filename at all, because the
##   node they sit on is generated. So `not probe.ok` discriminates
##   nothing for these two; what does is the refusal's text, the ABSENCE
##   of the ambiguous-call phrase, and the anchor.
## * the reflection object and the handle type — exit 1 with
##   `redefinition of 'L3resvPackageExports'` / `…SsoHandle`, again on a
##   generated line. Same reasoning.
## * `registerActivityInterface` / `registerServiceInterface` — exit
##   **0**: they COMPILED, because the emitted accessor merely overloads
##   the imported two-argument routine and the lift's own call still
##   resolves by arity. Reserving them is therefore a TIGHTENING rather
##   than a bug fix, and `not probe.ok` IS the discriminator there. It is
##   reserved because the name is the lift's and a future emission that
##   changed that call's arity would break in generated code for an
##   author who cannot see it.
## * the PACKAGE'S OWN TYPE, `L3resvPackage` — exit 1 with
##   `redefinition of 'L3resvPackage'; previous declaration here:
##   (3, 3)`, no filename on either location. This one is a name the
##   emission only REFERENCES — it is the `pkg:` parameter type of
##   every signature the lift writes — and it collides anyway because
##   `toolActionWrapperCode` declares it in the SAME module
##   (`macros_a.nim`, `type <Title>Package* = object`), so an accessor
##   `proc` of that name is a redefinition rather than an overload of an
##   import. The five OTHER referenced types — `LiftedServiceHandle`,
##   `ActivityInterfaceDef`, `ActivityParamInterfaceDef`,
##   `ActivityConfigInterfaceDef`, `ServiceInterfaceDef` — all live in
##   `types.nim` and are imported, each measured exit 0 as a service
##   name at `60bdcbbbb`, so they are deliberately NOT reserved.
##
## No case asserts only the exit code. Each asserts the refusal's
## DIAGNOSTIC TEXT and the anchor: the reported line is the line of the
## author's own declaration in the recipe, computed from the fixture
## rather than written down.
##
## The positive control is `probe.ok` on the unedited fixture, whose
## export names are all legal. It is what stops a reservation that
## refuses every name from passing this file.
##
## Governing text:
##
## * `Shared-Development-Services.md` §3 — "`infra.sso` is a typed
##   symbol"; the symbol has to be nameable.
## * L3 `:gate:` — "a message naming what is available".

import std/[strutils, unittest]

import ./service_block_compile_probe

const Producer = """
import repro_project_dsl

package l3resv:
  defaultToolProvisioning "path"

  devEnv:
    activity sso(host: string):
      ## The organisation's identity provider.
      config:
        ## Loopback port the issuer binds.
        port: int = 8080

      service zitadel:
        args "start-from-init", "--host", host

  service standalone:
    args "--standalone"
"""

const
  # Derived by the same rule the macro uses (`l3PackageExportsTypeName`
  # and `l3ActivityHandleTypeName`): `titleIdent("l3resv")` is
  # `L3resvPackage`, and the suffixes are the macro's own.
  ExportsObject = "L3resvPackageExports"
  SsoHandleType = "L3resvPackageSsoHandle"
  PackageType = "L3resvPackage"
  AmbiguousCallPhrase = "leads to ambiguous calls"
  RedefinitionPhrase = "redefinition of"

proc editedProducer(needle, replacement: string): string =
  ## One-line edit to `Producer`. Raises rather than returning a
  ## misleading result when the needle is absent, so a drifted fixture is
  ## a red test and not a silently vacuous one.
  if not Producer.contains(needle):
    raise newException(ValueError,
      "fixture drift: Producer no longer contains " & needle)
  result = Producer.replace(needle, replacement)
  doAssert result != Producer

proc declarationLine(source, needle: string): int =
  ## The 1-based line of `needle` in `source`. The refusal must be
  ## anchored on the AUTHOR's declaration, so the expected line number is
  ## read off the fixture instead of being transcribed.
  var n = 0
  for line in source.splitLines():
    inc n
    if line.contains(needle):
      return n
  raise newException(ValueError, "needle not found: " & needle)

proc probeFor(needle, replacement, tag: string):
    tuple[probe: ServiceCompileProbeResult; line: int] =
  let source = editedProducer(needle, replacement)
  result.probe = checkRecipeSource(source, tag)
  result.line = declarationLine(source, replacement.strip())

proc anchoredAt(probe: ServiceCompileProbeResult; line: int): bool =
  ## True when some `Error:` line of the output is anchored at `line` of
  ## the recipe the probe wrote.
  for outLine in probe.output.splitLines():
    if outLine.contains("recipe.nim(" & $line & ", ") and
       outLine.contains("Error:"):
      return true
  false

suite "L3 — the lift reserves the names it emits: the control":

  test "the positive control: legal export names compile":
    # Without this, a reservation that refused EVERY name would satisfy
    # every refusal case below.
    let probe = checkRecipeSource(Producer, "l3-reserved-control")
    checkpoint(probe.output)
    check probe.ok

suite "L3 — `liftedExports` is reserved, at both export levels":

  test "a package-level service named `liftedExports` is refused":
    let r = probeFor("service standalone:", "service liftedExports:",
      "l3-reserved-svc-liftedexports")
    checkpoint(r.probe.output)
    check not r.probe.ok
    # The refusal, naming the reserved word and what emits it.
    check r.probe.mentions("`service liftedExports`")
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("the lift itself emits it at module scope")
    check r.probe.mentions("package `l3resv`")
    check r.probe.mentions("Rename the service.")
    # Anchored on the author's own `service` head, not on generated code.
    check anchoredAt(r.probe, r.line)
    # The before-state, and the reason this suite exists: Nim's
    # ambiguous-call error against generated code must be GONE.
    check not r.probe.mentions(AmbiguousCallPhrase)

  test "an activity named `liftedExports` is refused":
    let r = probeFor("activity sso(host: string):",
      "activity liftedExports(host: string):",
      "l3-reserved-act-liftedexports")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("`activity liftedExports`")
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("Rename the activity.")
    check anchoredAt(r.probe, r.line)
    check not r.probe.mentions(AmbiguousCallPhrase)

suite "L3 — the rest of the emitted module-scope set is reserved too":

  test "the reflection object's type name is reserved":
    let r = probeFor("service standalone:", "service " & ExportsObject & ":",
      "l3-reserved-exports-object")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("the generated reflection object `" &
      ExportsObject & "`")
    check anchoredAt(r.probe, r.line)

  test "a generated handle type name is reserved":
    let r = probeFor("service standalone:", "service " & SsoHandleType & ":",
      "l3-reserved-handle-type")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("the generated handle type for activity `sso`")
    check anchoredAt(r.probe, r.line)

  test "the registry call names are reserved":
    # The one pair that COMPILED at `68abb6308` (see the header): the
    # accessor only overloads the imported two-argument routine. Here
    # `not probe.ok` is the discriminator, and it is checked first.
    for callName in ["registerActivityInterface", "registerServiceInterface"]:
      let r = probeFor("service standalone:", "service " & callName & ":",
        "l3-reserved-" & callName.toLowerAscii())
      checkpoint(r.probe.output)
      check not r.probe.ok
      check r.probe.mentions("`service " & callName & "`")
      check r.probe.mentions("is RESERVED")
      check r.probe.mentions("the registry call the lift emits")
      check anchoredAt(r.probe, r.line)

  test "the package's own type name is reserved":
    # The name the emission only REFERENCES. It is the `pkg:` parameter
    # type of `liftedExports` and of every accessor, and it is declared
    # in the recipe's own module, so an export of that name is a
    # redefinition in the author's module — reported on a generated line
    # with no filename, which is the outcome being closed here.
    let r = probeFor("service standalone:", "service " & PackageType & ":",
      "l3-reserved-package-type")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("`service " & PackageType & "`")
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("the package's own type `" & PackageType & "`")
    check anchoredAt(r.probe, r.line)
    # The before-state: Nim's redefinition error against generated code,
    # on no line an author can act on, must be GONE.
    check not r.probe.mentions(RedefinitionPhrase)

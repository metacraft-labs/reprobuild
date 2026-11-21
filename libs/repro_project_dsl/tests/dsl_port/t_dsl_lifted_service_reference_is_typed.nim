## Shared-Development-Services L3 — a consuming project references a
## dependency's service and activity as TYPED SYMBOLS, and a misspelled
## name, an absent member and a type mismatch each fail the consumer's
## recipe COMPILATION with a message naming what is available.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case writes two real recipes — a producer project and a consumer
## project, as workspace siblings on a real filesystem — and compiles the
## consumer with the real ``nim`` this repo is built with. The text
## asserted on is the compiler's real output. See
## ``service_block_compile_probe.nim`` for why the in-process
## ``compiles`` spelling cannot be used for a ``package`` block (short
## version: measured, it answers *false* for every one, well-formed or
## not, so a refusal and its control would both be vacuous; filed as
## ``reprobuild-pm/issues/2026-10-08-package-macro-refusal-gates-are-
## vacuous-under-not-compiles.md``).
##
## Governing text:
##
## * ``Shared-Development-Services.md`` §3 — "``infra.sso`` is a typed
##   symbol. A misspelling, a member that does not exist, or a type that
##   does not match is a compile error in THIS project's recipe
##   compilation — not a runtime \"no such service\"." And: references in
##   the DSL are typed symbols with dot access; ``<package>:<name>`` is
##   the CLI disambiguation surface and never a DSL reference syntax.
## * L3 ``:gate:`` — "project B referencing project A's service as a
##   typed symbol; a misspelled name, an absent member and a type
##   mismatch each failing B's recipe compilation with a message naming
##   what is available".
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, AND IT IS NOT THE SAME ONE IN
## EVERY TEST.
##
## * The positive control is ``probe.ok``, and at the base commit it is
##   FALSE: the producer exports no ``sso`` symbol at all, so the
##   consumer's ``l3prod.sso`` is an undeclared field. ``probe.ok`` is
##   therefore the real discriminator there.
## * The three refusal tests do NOT compile at the base either — for the
##   wrong reason, which is exactly the trap L2's review recorded. So
##   ``not probe.ok`` discriminates nothing in them, and none of them
##   asserts only that. Each asserts the DIAGNOSTIC TEXT, which is
##   absent at the base and present after.
##
## HOW THE TWO ROUTES RELATE. This file exercises the WORKSPACE-SIBLING
## route (``usesImportCode`` Branch C: the consumer imports the
## producer's own macro expansion). The lift-ARTIFACT route — the stub
## ``writeNimInterfaceStub`` writes for a consumer that never sees the
## producer's source — is exercised by
## ``libs/repro_interface_artifacts/tests/
## t_l3_lifted_symbols_compile_in_a_consumer.nim``, which checks the SAME
## consumer expressions against the generated stub. Two emitters, one
## surface; a divergence between them would otherwise be silent.

import std/[strutils, unittest]

import ./service_block_compile_probe

const Producer = """
import repro_project_dsl

type
  L3ProbeDb* = object
    connectionString*: string
    host*: string

package l3prod:
  defaultToolProvisioning "path"

  devEnv:
    activity sso(db: L3ProbeDb):
      ## The organisation's identity provider.
      config:
        ## The externally visible issuer host.
        externalDomain: string
        ## Loopback port the issuer binds.
        port: int = 8080

      service zitadel:
        args "start-from-init", "--host", db.host

  service standalone:
    args "--standalone"
"""

const Consumer = """
import repro_project_dsl

package l3consumer:
  defaultToolProvisioning "path"

  uses:
    "l3prod"

  devEnv:
    ## `l3prod.sso` is a typed symbol carried by the lift, and
    ## `L3prodPackageSsoHandle` is the handle TYPE it is typed by.
    activity stack(sso: L3prodPackageSsoHandle):
      service api:
        args "--port", $sso.port, "--issuer", sso.externalDomain,
             "--upstream", sso.zitadel.serviceName

    ## A second activity taking a plain service handle, so the
    ## type-mismatch case has somewhere to land that does not also
    ## trip the member check.
    activity edge(svc: LiftedServiceHandle):
      service edgeProxy:
        args "--for", svc.serviceName

    enable stack(sso = l3prod.sso)
    enable edge(svc = l3prod.standalone)
"""

proc editedConsumer(needle, replacement: string): string =
  ## One-line edit to ``Consumer``. Raises rather than returning a
  ## misleading result when the needle is not present, so a drifted
  ## fixture is a red test and not a silently vacuous one.
  if not Consumer.contains(needle):
    raise newException(ValueError,
      "fixture drift: Consumer no longer contains " & needle)
  result = Consumer.replace(needle, replacement)
  doAssert result != Consumer

proc edited(needle, replacement, tag: string): ServiceCompileProbeResult =
  checkConsumerWithProducer("l3prod", Producer,
    editedConsumer(needle, replacement), tag)

suite "L3 — project B compiles against project A's lifted symbols":

  test "the positive control: the whole cross-package shape compiles":
    # The control for every refusal below. At the base commit this FAILS
    # (the producer exports no `sso`), which makes `probe.ok` the
    # discriminator here and nowhere else in this file.
    let probe = checkConsumerWithProducer("l3prod", Producer, Consumer,
      "l3-xpkg-wellformed")
    checkpoint(probe.output)
    check probe.ok

suite "L3 — a misspelled export name is refused, naming the exports":

  test "it does not compile, and the message names what A exports":
    let probe = edited("l3prod.sso", "l3prod.ssoo", "l3-xpkg-bad-name")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("exports no service or activity named `ssoo`")
    check probe.mentions(
      "services and activities package `l3prod` exports:")
    # Both kinds, in the one list: the activity and the package-level
    # service. A message naming only one of them would send an author
    # looking in the wrong half of the producer.
    check probe.mentions("sso")
    check probe.mentions("standalone")

  test "the refusal quotes the spec rule it is enforcing":
    let probe = edited("l3prod.sso", "l3prod.ssoo", "l3-xpkg-bad-name-rule")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("not a runtime")

suite "L3 — an absent member of a lifted handle is refused":

  test "a `config:` key that does not exist, with the members that do":
    let probe = edited("$sso.port", "$sso.prot", "l3-xpkg-bad-config-member")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("has no member `prot`")
    check probe.mentions("L3prodPackageSsoHandle")
    # The handle's members are the `config:` keys AND the services the
    # activity declares — both halves named, because the lift carries
    # both.
    check probe.mentions("externalDomain")
    check probe.mentions("port")
    check probe.mentions("zitadel")

  test "a SERVICE that the activity does not declare":
    let probe = edited("sso.zitadel.serviceName",
      "sso.zitadl.serviceName", "l3-xpkg-bad-service-member")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("has no member `zitadl`")
    check probe.mentions("zitadel")

  test "a member reached DIRECTLY off the dependency const is refused too":
    # `l3prod.sso.prot` rather than through an activity parameter: the
    # same mistake one dot earlier, and the one L2's
    # `activityMemberRefusal` cannot see because the base is not a
    # parameter.
    let probe = edited("enable stack(sso = l3prod.sso)",
      "enable stack(sso = l3prod.sso)\n    discard l3prod.sso.prot",
      "l3-xpkg-direct-member")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("has no member `prot`")
    check probe.mentions("the lifted handle `l3prod.sso`")
    check probe.mentions("externalDomain")

suite "L3 — a type mismatch is refused by the compiler, naming the type":

  test "passing an activity handle where a service handle is expected":
    # Deliberately NOT a DSL refusal: Nim's own diagnostic names both the
    # type it got and the type it expected, which is what "naming what is
    # available" means for a mismatch, and a DSL refusal would have to
    # re-implement overload resolution to fire at the right times. The
    # assertion is on Nim's text, so a regression that made this compile
    # silently is still caught.
    let probe = edited("enable edge(svc = l3prod.standalone)",
      "enable edge(svc = l3prod.sso)", "l3-xpkg-type-mismatch")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("type mismatch")
    check probe.mentions("L3prodPackageSsoHandle")
    check probe.mentions("LiftedServiceHandle")

  test "the control: the same `enable` with the RIGHT type compiles":
    # Without it, the test above would pass on a producer that exports
    # neither symbol.
    let probe = checkConsumerWithProducer("l3prod", Producer, Consumer,
      "l3-xpkg-type-control")
    checkpoint(probe.output)
    check probe.ok

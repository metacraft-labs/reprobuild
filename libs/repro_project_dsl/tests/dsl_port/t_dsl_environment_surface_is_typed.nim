## Shared-Development-Services L5 — THE NEGATIVE SURFACE, which the
## milestone's `:gate:` calls its point:
##
##   "a consumer-side attempt to bind an environment-owned configurable
##    failing the CONSUMER'S recipe compilation rather than producing a
##    second instance quietly — that negative is the milestone's point,
##    because the permissive version of this feature passes every
##    positive test."
##
## and the other half of §6.6's line, which must still COMPILE:
##
##   "A consumer may still override the instance SCOPE and its own lease
##    policy — that is the line spec §6.6 draws, and both sides of it are
##    tested."
##
## WHICH DISCRIMINATOR IS LOAD-BEARING, STATED EXPLICITLY. `probe.ok` is
## the discriminator for the two POSITIVE controls only (the well-formed
## single recipe, and the well-formed cross-package consumer). For every
## refusal the discriminator is the MESSAGE TEXT, not the exit code,
## and the reason is specific: at the base commit `8a85af3eb`
## `environment` is not a known package section, so EVERY fixture in
## this file — well-formed or not — fails to compile. An exit-code
## assertion would therefore be satisfied at the base by a recipe that
## is simply unsupported, which is the "useless because the base already
## failed to compile" trap this campaign has hit three times. The
## positive controls are what make the exit code mean something here:
## they turn red at the base, and the refusals assert on text no
## undeclared-identifier error contains.
##
## NEVER `check not compiles(...)`. `service_block_compile_probe.nim`'s
## header records the measurement: `compiles` is false for every
## `package` block inside a `block:` expression, well-formed ones
## included, so the assertion passes whether or not the refusal exists.
## Every negative here is an out-of-process `nim check` / `nim c` probe.
##
## MOCK POLICY — NO MOCKS. Real recipes on a real filesystem, compiled
## by the real `nim`, and the text asserted on is its real output.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

package l5surface:
  defaultToolProvisioning "path"

  config:
    issuer: string = "http://localhost:8080"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        externalSecure: bool = false

      service zitadel:
        args "--domain", externalDomain

  environment dev:
    issuer = "https://login.metacraft-labs.test"
    sso.externalDomain = "login.metacraft-labs.test"
    sso.externalSecure = true

  instanceOverrides l5surface.zitadel:
    scope workspace
    lease keep
"""

proc edited(needle, replacement: string): string =
  ## One-line edit to `WellFormed`. Raises rather than returning a
  ## misleading result when the needle is absent, so a drifted fixture
  ## is a red test and not a silently vacuous one.
  if not WellFormed.contains(needle):
    raise newException(ValueError,
      "fixture drift: WellFormed no longer contains " & needle)
  result = WellFormed.replace(needle, replacement)
  doAssert result != WellFormed

proc probeEdited(needle, replacement, tag: string):
    ServiceCompileProbeResult =
  checkRecipeSource(edited(needle, replacement), tag)

## ---------------------------------------------------------------------
## The cross-package fixtures. The producer DECLARES the configurable
## AND BINDS IT IN ITS OWN ENVIRONMENT, which is what makes the
## consumer's attempt a §6.6 case rather than a typo: the key exists,
## the producer owns it, and the consumer still may not bind it.
## ---------------------------------------------------------------------

const Producer = """
import repro_project_dsl

package l5prod:
  defaultToolProvisioning "path"

  devEnv:
    activity sso():
      ## The organisation's identity provider.
      config:
        ## The externally visible issuer host.
        externalDomain: string = "localhost"
        port: int = 8080

      service zitadel:
        args "start-from-init", "--host", externalDomain
        identity stable "com.example.sso"
        scope workspace

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
"""

const Consumer = """
import repro_project_dsl

package l5consumer:
  defaultToolProvisioning "path"

  uses:
    "l5prod"

  config:
    apiPort: int = 3000

  ## §6.6's LEFT column: this consumer's OWN instance scope and lease
  ## policy for somebody else's service. Permitted, and it compiles.
  instanceOverrides l5prod.zitadel:
    scope workspace
    lease delayed(600)

  ## An environment of its OWN, binding its OWN configurable. Permitted.
  environment dev:
    apiPort = 3100
"""

const ForbiddenBinding = """
  ## §6.6's RIGHT column: binding the producer's environment-owned
  ## configurable. This must fail THIS recipe's compilation.
  environment devLocal:
    l5prod.sso.externalDomain = "login.attacker.test"
"""

## ---------------------------------------------------------------------
## THE REQUIRED-KEY fixtures. Each is a WHOLE recipe rather than an edit
## of `WellFormed`, and that is deliberate: the property under test is a
## COMBINATION (the key is declared, and something either does or does
## not satisfy it), and two independent one-line edits of a shared
## fixture cannot express a combination -- each edit starts from the
## unedited original. That is the vacuous shape this suite's first
## revision shipped, recorded at the suite below.
##
## A `config:` key declared with NO DEFAULT is a REQUIRED CONFIGURABLE:
## the slot exists and has no seed, and §6 gives it exactly two routes
## to a value -- an `environment` binding, or an argument at
## `enable <activity>(...)`. The three fixtures are those two routes and
## their absence.
##
## AN EARLIER REVISION REFUSED THE FIRST OF THEM, and the first fixture
## below is `Shared-Development-Services.md`'s own §6 / §9.1 example, so
## that refusal made the spec illegal. The refusals that replaced it are
## narrower and there are two, because they mean different things.
## ---------------------------------------------------------------------

const RequiredBoundByEnvironment = """
import repro_project_dsl

package l5reqenv:
  defaultToolProvisioning "path"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        adminUser: string

      service zitadel:
        args "--domain", externalDomain, "--admin", adminUser

    enable sso

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
    sso.adminUser = "root"
"""

const RequiredUnsatisfiable = """
import repro_project_dsl

package l5requnsat:
  defaultToolProvisioning "path"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        adminUser: string

      service zitadel:
        args "--domain", externalDomain, "--admin", adminUser

    enable sso

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
"""

const RequiredSuppliedAtEnable = """
import repro_project_dsl

package l5reqenable:
  defaultToolProvisioning "path"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        adminUser: string

      service zitadel:
        args "--domain", externalDomain, "--admin", adminUser

    enable sso(adminUser = "root")

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
"""

const RequiredSuppliedInOverrideBody = """
import repro_project_dsl

package l5reqoverride:
  defaultToolProvisioning "path"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        adminUser: string

      service zitadel:
        args "--domain", externalDomain, "--admin", adminUser

    enable sso:
      adminUser "root"

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
"""

const RequiredNeverEnabled = """
import repro_project_dsl

package l5reqnoenable:
  defaultToolProvisioning "path"

  devEnv:
    activity sso():
      config:
        externalDomain: string = "localhost"
        adminUser: string

      service zitadel:
        args "--domain", externalDomain, "--admin", adminUser

  environment dev:
    sso.externalDomain = "login.metacraft-labs.test"
"""

const UnsupportedTypeBound = """
import repro_project_dsl

package l5unsup:
  defaultToolProvisioning "path"
  config:
    tags: seq[string] = @["a"]
  environment dev:
    tags = @["b"]
"""

const SupportedSeqEnumBound = """
import repro_project_dsl

type L5Slot = enum l5slotA, l5slotB

package l5seqenum:
  defaultToolProvisioning "path"
  config:
    kinds: seq[L5Slot] = @[l5slotA]
  environment dev:
    kinds = @[l5slotB]
"""

suite "L5 — the positive controls":

  test "a well-formed recipe with an environment block compiles":
    # THE control for this whole file. `probe.ok` is the discriminator
    # here and in the cross-package control below, and nowhere else: at
    # the base commit this is RED, because `environment dev:` reaches
    # the preserved-Nim bucket as an undeclared identifier.
    let probe = checkRecipeSource(WellFormed, "l5-wellformed")
    checkpoint(probe.output)
    check probe.ok

  test "the cross-package control: a consumer that stays inside §6.6's left column compiles":
    let probe = checkConsumerWithProducer("l5prod", Producer, Consumer,
      "l5-xpkg-control")
    checkpoint(probe.output)
    check probe.ok

suite "L5 — §6.6: a CONSUMER may not bind an environment-owned configurable":

  test "the consumer's own compilation fails, and names the owner":
    # The milestone's point. The producer declares `sso.externalDomain`
    # AND binds it in its own `environment dev:`, so this is not a typo
    # case: the key exists and the consumer still may not bind it.
    let probe = checkConsumerWithProducer("l5prod", Producer,
      Consumer & ForbiddenBinding, "l5-xpkg-forbidden")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("names package `l5prod`'s configurable")
    check probe.mentions("A consumer may not bind a configurable " &
      "another package's environment owns")

  test "the refusal quotes §6.6 and names where scope and lease DO go":
    # A refusal that only says no leaves the author with the same
    # problem. §6.6's left column is reachable and the message says so.
    let probe = checkConsumerWithProducer("l5prod", Producer,
      Consumer & ForbiddenBinding, "l5-xpkg-forbidden-msg")
    checkpoint(probe.output)
    check probe.mentions("Shared-Development-Services.md` §6.6")
    check probe.mentions("instanceOverrides <package>.<service>:")
    check probe.mentions("package `l5consumer` declares: apiPort")

  test "the SHORT spelling of the same attempt is refused the same way":
    # `sso.externalDomain = ...` where `sso` is a dependency's activity
    # rather than this package's. Same §6.6 case, different spelling; an
    # implementation that keyed the refusal on segment count would let
    # this one through.
    let probe = probeEdited(
      "  environment dev:\n    issuer =",
      "  environment dev:\n    notMyActivity.externalDomain = \"x\"\n    issuer =",
      "l5-foreign-activity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions(
      "`notMyActivity` is not an activity this package declares")
    check probe.mentions("its own environment binds them")

  test "a key this package simply has no config: entry for is a DIFFERENT message":
    # The discriminator that keeps the §6.6 refusal from being a generic
    # unknown-name error wearing a spec citation: a misspelled key of
    # THIS package gets the unknown-key message, not the ownership one.
    let probe = probeEdited("issuer = \"https://login.metacraft-labs.test\"",
      "issuerr = \"https://login.metacraft-labs.test\"", "l5-unknown-key")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("which this package declares no `config:` key for")
    check probe.mentions("package `l5surface` declares: issuer, " &
      "sso.externalDomain, sso.externalSecure")
    check not probe.mentions("A consumer may not bind")

suite "L5 — a REQUIRED `config:` key: both routes compile, and nothing else does":
  ## §6's OWN example, which an earlier revision of this walker REFUSED.
  ##
  ## `Shared-Development-Services.md` line 421 (§6's worked example) and
  ## line 646 (§9.1's) both declare `externalDomain: string` -- no
  ## default -- and bind it from an `environment` block. The refusal
  ## that stood here made both illegal. It was right against what it
  ## replaced (a key that was accepted and then silently had no slot)
  ## and wrong as an end state, because it conflated "no default" with
  ## "no slot". A key with no default is not slot-less; it is REQUIRED.
  ##
  ## WHAT THE FIRST REVISION OF THE NO-DEFAULT CASE DID WRONG, kept here
  ## because it is the failure mode this campaign keeps paying for. It
  ## made TWO INDEPENDENT `probeEdited` edits of `WellFormed`: one that
  ## added `adminUser: string` to the activity, and one that added
  ## `sso.adminUser = "root"` to the environment. Each edit starts from
  ## the UNEDITED `WellFormed`, so the binding probe bound a key its own
  ## fixture never declared, and the message it asserted on -- "declares
  ## no `config:` key for" -- was the UNKNOWN-KEY refusal, not the
  ## no-slot one. A test whose fixture cannot express the combination in
  ## its own name is vacuous however green it is. Every fixture in this
  ## suite is therefore a WHOLE recipe.

  test "§6's HEADLINE CASE: a required key BOUND BY AN ENVIRONMENT compiles":
    # Measured refused at the base: `environment `dev` ... binds
    # `sso.adminUser`, and ... is declared WITHOUT A DEFAULT`, from
    # `macros_b.nim`'s no-default binding guard. The value actually
    # reaching the service's argv and the rendered config is asserted in
    # `libs/repro_project_dsl/tests/
    # t_l5_environment_reaches_the_service_argv.nim` -- compiling is
    # necessary and not sufficient.
    let probe = checkRecipeSource(RequiredBoundByEnvironment,
      "l5-required-env")
    checkpoint(probe.output)
    check probe.ok

  test "THE OTHER ROUTE: a required key supplied at the `enable` site compiles":
    let probe = checkRecipeSource(RequiredSuppliedAtEnable,
      "l5-required-enable")
    checkpoint(probe.output)
    check probe.ok

  test "and supplied in the `enable` OVERRIDE BODY, which is the other spelling of that route":
    # `Package-Model.md`'s override-body form. The required-key check
    # reads it through `l2EnableOverridePair`, the same proc
    # `l2EnableEmission` reads, so the two cannot disagree about what a
    # site supplies. A check that only looked at the parentheses would
    # refuse this recipe.
    let probe = checkRecipeSource(RequiredSuppliedInOverrideBody,
      "l5-required-override-body")
    checkpoint(probe.output)
    check probe.ok

  test "a required key on an activity that is DECLARED AND NEVER ENABLED compiles":
    # The predicate is "some `enable` site leaves it unsupplied", not
    # "no `enable` site supplies it", and this is the shape that decides
    # it: an activity nobody enables never calls its entry point, so the
    # key is never read and there is nothing to drop. It is a real
    # shape, not a hypothetical -- `l3_lift_fixtures.nim`'s
    # `l3LiftProducer` is exactly this, so the stricter predicate would
    # have reddened L3's own fixtures.
    let probe = checkRecipeSource(RequiredNeverEnabled,
      "l5-required-never-enabled")
    checkpoint(probe.output)
    check probe.ok

  test "REFUSAL ONE OF TWO: a required key NOTHING CAN SATISFY is refused at expansion":
    # No environment of the package binds it and the `enable` site does
    # not pass it, so no selection can ever make this work. The check is
    # at EXPANSION precisely because it must not depend on which
    # environment is selected: a refusal that fired only on selection
    # would leave this defect silently inert for every other build.
    let probe = checkRecipeSource(RequiredUnsatisfiable,
      "l5-required-unsatisfiable")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("WITHOUT A DEFAULT, which makes it REQUIRED")
    check probe.mentions("NOTHING CAN EVER SATISFY IT")
    # BOTH routes named, which is the thing the author needs.
    check probe.mentions("environment <name>: sso.adminUser = <value>")
    check probe.mentions("enable sso(adminUser = <value>)")
    # NOT the unknown-key refusal: the key IS declared.
    check not probe.mentions("declares no `config:` key for")
    # NOT the OLD refusal, which this one replaces rather than joins.
    check not probe.mentions("has no configurable slot for an " &
      "environment to bind")

  test "the two refusals do not share their text, because they do not mean the same thing":
    # "This can never work" (expansion) against "this configuration does
    # not work" (resolution, `requiredConfigurableValue`, asserted in
    # the argv test). The resolution message's distinctive sentence must
    # NOT appear in the expansion one, or a reader cannot tell which
    # failure they have.
    let probe = checkRecipeSource(RequiredUnsatisfiable,
      "l5-required-distinct")
    checkpoint(probe.output)
    check probe.mentions("NOTHING CAN EVER SATISFY IT")
    check not probe.mentions("IS UNSATISFIED")
    check not probe.mentions("the selected environment")

  test "a key whose TYPE the configurable lane does not carry is refused, naming the type":
    # `emitM2ConfigDefaults` filters package-level entries through
    # `m2TypeReprIsSupportedScalar` and silently passes the rest
    # through, while `collectM2ConfigEntries` -- which the environment
    # walker reads -- does not. So this key was in the walker's
    # declared set with no slot behind it, and binding it failed inside
    # `dsl_port_runtime.nim` as `setConfigurable: unsupported type
    # seq[string]`: loud, but at a library line, with nothing about the
    # environment, the package or the key. Measured before the fix.
    let probe = checkRecipeSource(UnsupportedTypeBound, "l5-noslot-type")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("whose type `seq[string]` the configurable " &
      "lane does not carry")
    check probe.mentions("could never be in force")
    # The old failure's text, asserted ABSENT: the refusal has to
    # replace it, not arrive beside it.
    check not probe.mentions("M9.D seq support is restricted to seq[Enum]")
    # AND NOT the required-key refusal. "No default" and "unsupported
    # type" are two refusals and were deliberately not merged when the
    # first of them was narrowed: this key HAS a default and is still
    # slot-less.
    check not probe.mentions("which makes it REQUIRED")
    check not probe.mentions("NOTHING CAN EVER SATISFY IT")

  test "THE CONTROL: a `seq[<enum>]` key IS carried, and binding it compiles":
    let probe = checkRecipeSource(SupportedSeqEnumBound,
      "l5-noslot-type-control")
    checkpoint(probe.output)
    check probe.ok

suite "L5 — `environment <name>:` binds configurables and NOTHING else":

  test "a `service` declaration inside an environment body is refused":
    let probe = probeEdited("    sso.externalSecure = true",
      "    service rogue:\n      args \"--x\"", "l5-env-service")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not belong in an environment body")
    check probe.mentions("is not a machine and has no topology")

  test "an `activity` declaration inside an environment body is refused, citing D-SS8":
    let probe = probeEdited("    sso.externalSecure = true",
      "    activity rogue():\n      discard", "l5-env-activity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not belong in an environment body")
    check probe.mentions("stays a separate surface (D-SS8)")

  test "a `scope` setter inside an environment body is refused, and redirected":
    # The one most likely to be reached for, now that
    # `instanceOverrides` exists one block away. The message names it.
    let probe = probeEdited("    sso.externalSecure = true",
      "    scope workspace", "l5-env-scope")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("instanceOverrides <package>.<service>:` (§6.6)")

  test "an arbitrary statement in an environment body is refused, not dropped":
    let probe = probeEdited("    sso.externalSecure = true",
      "    echo \"hello\"", "l5-env-arbitrary")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a binding")
    check probe.mentions("REFUSED")

  test "a path deeper than <activity>.<name> inside THIS package is refused":
    let probe = probeEdited("    sso.externalSecure = true",
      "    sso.nested.deeper = true", "l5-env-deep")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("names package `sso`'s configurable")

  test "one configurable bound twice in one environment is refused":
    let probe = probeEdited("    sso.externalSecure = true",
      "    sso.externalSecure = true\n    sso.externalSecure = false",
      "l5-env-twice")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is bound twice")

suite "L5 — the `environment` HEAD itself, including the dotted spelling":

  test "the DOTTED head is refused by name, not dropped":
    # The standing hunt's one open defect is this exact shape on a
    # service setter (`identity.stable \"x\"`), so L5's own heads are
    # checked for it. Without the check the statement reaches the
    # preserved-Nim bucket and fails as `undeclared identifier:
    # environment` on a line the author did not write.
    let probe = probeEdited("  environment dev:", "  environment.dev:",
      "l5-head-dotted")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a declaration head, not a member")
    check probe.mentions("writes the name with a DOT")

  test "the dotted head on `instanceOverrides` is refused the same way":
    let probe = probeEdited("  instanceOverrides l5surface.zitadel:",
      "  instanceOverrides.l5surface:", "l5-head-dotted-ov")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a declaration head, not a member")

  test "an extra argument on the head is refused, not read past":
    let probe = probeEdited("  environment dev:",
      "  environment dev, alsoProduction:", "l5-head-extra")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("takes exactly one name")
    check probe.mentions("alsoProduction")

  test "a missing body is refused":
    let probe = probeEdited("  environment dev:\n    issuer =",
      "  environment dev\n  discard dev\n  environment devTwo:\n    issuer =",
      "l5-head-nobody")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("needs a block body")

  test "a STRING name is refused, naming the identifier form":
    let probe = probeEdited("  environment dev:", "  environment \"dev\":",
      "l5-head-string")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("names its environment with a STRING")
    check probe.mentions("a bare identifier")

  test "two environments under one name are refused":
    let probe = probeEdited("    sso.externalSecure = true",
      "    sso.externalSecure = true\n\n  environment dev:\n    issuer = \"x\"",
      "l5-head-dup")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is declared twice in package")

suite "L5 — D-SS8 holds in BOTH directions":
  ## The `environment` walker refuses `activity` / `enable` / `devEnv`
  ## inside its body (above). These are the mirror: an L5 head written
  ## inside a `devEnv:` body or an activity body. Before the mirror
  ## existed both reached the verbatim passthrough and failed as
  ## `undeclared identifier: environment` -- loud, so not a drop, but
  ## saying nothing about where the declaration belongs. Found by this
  ## milestone's own sweep of the surfaces it adds.

  test "`environment` inside a `devEnv:` body is refused by name":
    let probe = probeEdited("    activity sso():",
      "    environment rogue:\n      sso.externalDomain = \"x\"\n\n" &
      "    activity sso():", "l5-env-in-devenv")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a PACKAGE-LEVEL declaration and does not " &
      "belong here")
    check probe.mentions("separate surfaces (D-SS8)")

  test "`environment` inside an ACTIVITY body is refused by name":
    let probe = probeEdited("      service zitadel:",
      "      environment rogue:\n        externalDomain = \"x\"\n\n" &
      "      service zitadel:", "l5-env-in-activity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a PACKAGE-LEVEL declaration and does not " &
      "belong here")

  test "the DOTTED L5 head inside a `devEnv:` body is refused by name too":
    # `l2RefuseL5HeadsHere` returned early on a non-ident head, so
    # `environment.dev:` inside a `devEnv:` body reached the verbatim
    # passthrough and gave `undeclared identifier: 'environment'` --
    # loud but mislocated, and it is the DOTTED shape of the standing
    # hunt's open issue. Measured before the fix: the output carried
    # `undeclared identifier` and none of this refusal's text.
    let probe = probeEdited("    activity sso():",
      "    environment.dev:\n      sso.externalDomain = \"x\"\n\n" &
      "    activity sso():", "l5-env-dotted-in-devenv")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a PACKAGE-LEVEL declaration and does not " &
      "belong here")
    check not probe.mentions("undeclared identifier: 'environment'")

  test "`instanceOverrides` inside a `devEnv:` body is refused the same way":
    let probe = probeEdited("    activity sso():",
      "    instanceOverrides other.svc:\n      scope user\n\n" &
      "    activity sso():", "l5-ov-in-devenv")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`instanceOverrides` is a PACKAGE-LEVEL " &
      "declaration")

suite "L5 — D-SS6: an environment does not bind a VARIANT":
  ## All THREE spellings a variant has in this DSL, because the first
  ## version of this check caught only two: the explicit inner form is
  ## not matched by `m2ConfigEntryAst` at all, so its name was never
  ## collected and it fell through to the generic unknown-key message.

  test "the explicit `variant T = default` inner form is refused":
    let probe = checkRecipeSource("""
import repro_project_dsl

package l5varA:
  defaultToolProvisioning "path"
  config:
    buildKind:
      variant string = "debug"
  environment dev:
    buildKind = "release"
""", "l5-variant-explicit")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("which is a VARIANT rather than a plain " &
      "`config:` key")
    check probe.mentions("(D-SS6;")

  test "the `## @variant` doc-directive form is refused":
    let probe = checkRecipeSource("""
import repro_project_dsl

package l5varB:
  defaultToolProvisioning "path"
  config:
    ## @variant
    buildKind: string = "debug"
  environment dev:
    buildKind = "release"
""", "l5-variant-directive")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("which is a VARIANT rather than a plain " &
      "`config:` key")

  test "a plain key driven by a `variant <name>:` ARM BLOCK is refused":
    # The spelling a real recipe in this repository uses
    # (`t_dsl_variant_uses.nim`): the `config:` entry is plain, and a
    # separate top-level `variant <name>:` block drives it. That key
    # DOES reach `recordConfigDefault`, so without the third arm of the
    # collector an environment could bind it.
    let probe = checkRecipeSource("""
import repro_project_dsl

type L5Dk = enum l5dkA, l5dkB

package l5varC:
  defaultToolProvisioning "path"
  config:
    desktopKind: seq[L5Dk] = @[l5dkA]
  variant desktopKind:
    `case` l5dkA:
      uses "sway >=0.1.0"
    `case` l5dkB:
      uses "gnome >=0.1.0"
  environment dev:
    desktopKind = @[l5dkB]
""", "l5-variant-arms")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("which is a VARIANT rather than a plain " &
      "`config:` key")

  test "the ALTERNATIVE SPELLINGS of the arm-block variant are refused too":
    ## THE DEFECT THIS CASE EXISTS FOR, and it defeated D-SS6 entirely.
    ## The guard read `if qualifier.len == 0 and name in variants:` --
    ## the author's spelling compared VERBATIM against verbatim-collected
    ## variant names -- while `l5FindDecl` three lines below normalizes
    ## BOTH sides. Nim identifiers are case- and underscore-insensitive
    ## after the first character, so an alternative spelling walked past
    ## the guard, was resolved onto the variant's OWN key, and the
    ## binding was ACCEPTED AND APPLIED. Measured against this exact
    ## recipe shape: `desktopKind = @[l5dkB]` refused, `desktopkind =
    ## @[l5dkB]` and `desktop_kind = @[l5dkB]` both `nim check` exit 0.
    ##
    ## One case per bypassing spelling, in a loop so a third cannot be
    ## added to the implementation's blind spot without being added
    ## here: the loop body is the assertion, not a sample of it.
    for spelling in ["desktopkind", "desktop_kind", "DESKTOPKIND",
                     "desktop_Kind"]:
      let probe = checkRecipeSource("""
import repro_project_dsl

type L5Dk = enum l5dkA, l5dkB

package l5varE:
  defaultToolProvisioning "path"
  config:
    desktopKind: seq[L5Dk] = @[l5dkA]
  variant desktopKind:
    `case` l5dkA:
      uses "sway >=0.1.0"
    `case` l5dkB:
      uses "gnome >=0.1.0"
  environment dev:
    """ & spelling & """ = @[l5dkB]
""", "l5-variant-spelling-" & spelling)
      checkpoint(spelling & ": " & probe.output)
      check not probe.ok
      check probe.mentions("which is a VARIANT rather than a plain " &
        "`config:` key")

  test "an alternative spelling of the DOC-DIRECTIVE variant is refused too":
    # The collector's other arm, de-duplicated with the same
    # normalising membership test. Separate from the loop above because
    # it exercises a different arm of `l5CollectVariantNames`.
    let probe = checkRecipeSource("""
import repro_project_dsl

package l5varF:
  defaultToolProvisioning "path"
  config:
    ## @variant
    buildKind: string = "debug"
  environment dev:
    build_kind = "release"
""", "l5-variant-directive-spelling")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("which is a VARIANT rather than a plain " &
      "`config:` key")

  test "THE CONTROL: the same recipe without the variant arms compiles":
    # Without this, the three refusals above could be failing for any
    # reason the fixture happens to carry.
    let probe = checkRecipeSource("""
import repro_project_dsl

type L5Dk2 = enum l5dk2A, l5dk2B

package l5varD:
  defaultToolProvisioning "path"
  config:
    desktopKind: seq[L5Dk2] = @[l5dk2A]
  environment dev:
    desktopKind = @[l5dk2B]
""", "l5-variant-control")
    checkpoint(probe.output)
    check probe.ok

suite "L5 — §6.6's left column: `instanceOverrides` accepts two things":

  test "a configurable binding inside it is refused as the right column":
    let probe = probeEdited("    lease keep",
      "    lease keep\n    issuer = \"https://nope.test\"", "l5-ov-bind")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("BINDS a configurable, and a consumer may not")

  test "an `identity` statement inside it is refused as the owner's":
    let probe = probeEdited("    lease keep",
      "    identity stable \"com.example.hijack\"", "l5-ov-identity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is the OWNER's statement about its own service")

  test "an unknown scope word is refused, naming the four":
    let probe = probeEdited("    scope workspace", "    scope cluster",
      "l5-ov-scope-word")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a scope; the scopes are")
    check probe.mentions("`workspace`")

  test "a quoted scope is refused":
    let probe = probeEdited("    scope workspace", "    scope \"workspace\"",
      "l5-ov-scope-string")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("names its scope with a STRING")

  test "`lease delayed` with no ttl is refused, naming the spelling":
    let probe = probeEdited("    lease keep", "    lease delayed",
      "l5-ov-lease-nottl")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("needs a ttl in seconds: `lease delayed(900)`")

  test "a COMPUTED ttl is refused: the deadline is not a function of the build":
    let probe = probeEdited("    lease keep", "    lease delayed(someProc())",
      "l5-ov-lease-computed")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("needs an INTEGER LITERAL of seconds")

  test "an unknown lease policy is refused":
    let probe = probeEdited("    lease keep", "    lease forever",
      "l5-ov-lease-word")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a lease policy")

  test "an unrecognised statement is refused, not dropped":
    let probe = probeEdited("    lease keep", "    somethingElse 42",
      "l5-ov-unknown")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a recognised statement")

  test "an unqualified target is refused: an override is per consuming edge":
    let probe = probeEdited("  instanceOverrides l5surface.zitadel:",
      "  instanceOverrides zitadel:", "l5-ov-target")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("names its target as `<package>.<service>`")

  test "a SECOND block for the same target is refused, not silently ignored":
    # A silently-dropped construct the standing hunt found: two
    # `instanceOverrides <same target>:` blocks compiled clean, both
    # rows were appended, and the lookup returns the FIRST -- so the
    # second author's `scope` was accepted and had no effect.
    let probe = probeEdited("    lease keep",
      "    lease keep\n\n  instanceOverrides l5surface.zitadel:\n" &
      "    scope user", "l5-ov-dup")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is declared twice in package")
    check probe.mentions("accepted and then ignored")

  test "a body declaring NEITHER scope nor lease is refused":
    # It would write a record indistinguishable from no record, so an
    # author who wrote it and expected something got nothing.
    let probe = probeEdited("    scope workspace\n    lease keep",
      "    discard", "l5-ov-empty")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("declares neither `scope` nor `lease`")

  test "a DOTTED environment NAME is refused, as not a name at all":
    let probe = probeEdited("  environment dev:", "  environment dev.local:",
      "l5-head-dotted-name")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a name. An environment's name is a bare " &
      "identifier")

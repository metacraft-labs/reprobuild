## Shared-Development-Services L4 — the ``identity`` and ``scope`` setters
## of a ``service`` block, and the fact that every spelling they do not
## recognise is REFUSED rather than dropped.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real ``nim`` this
## repo is built with and asserts on its real output. See
## ``service_block_compile_probe.nim`` for why the in-process
## ``check not compiles(...)`` spelling cannot be used for a ``package``
## block (measured: it answers *false* for every one, well-formed or not,
## so a refusal and its control would both be vacuous).
##
## WHICH DISCRIMINATOR EACH CASE RESTS ON, decided rather than assumed.
## This campaign has twice shipped a refusal test whose exit code did not
## move, because the base recipe already failed to compile. That is NOT
## the case here, and the reason is the defect under test: at the base
## commit every spelling below — the well-formed ones AND the malformed
## ones — compiles with exit 0, because ``m5ParseServiceBody`` ends in
## ``else: discard`` and skips anything that is not a recognised setter,
## and skips entirely anything that is not an ``nnkCall``/``nnkCommand``.
## So for every refusal here the EXIT STATUS genuinely discriminates
## (0 before, non-zero after) and it is asserted. The DIAGNOSTIC TEXT is
## asserted beside it, because "the build stops" is not the requirement:
## an author who wrote ``identity stable`` has to be told that the id is
## missing and why a stable identity needs one.
##
## Governing spec text — ``Shared-Development-Services.md``:
##
## * §4.1 "``project`` | one instance per project root — the default, and
##   today's only behaviour"; ``workspace`` | ``user`` | ``system``.
## * §4.2 "``stable \"<id>\"`` — declared identity. The author assigns a
##   stable identifier, independent of the build."
## * §4.2 "A stable identifier is a name, not a secret, and it is chosen
##   to be globally unique by construction … It is not derived from a
##   path, because a path is what distinguishes the worktrees that are
##   supposed to share the instance."
## * §4.2 the author's rule: "a service declares ``stable`` if and only
##   if it owns state that must outlive a change to its own definition."
##
## Every refusal is a one-line edit to ONE well-formed recipe, and that
## recipe's own compile is the first test in the file. The two guards L1's
## sibling file earned are kept: each case asserts the edit actually
## changed the source, and each refusal asserts on the message.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl
import repro_dsl_stdlib/types

var probeConfig: BuildOutput

package l4probeRecipe:
  executable probeBin:
    build:
      output("bin/probe")

  build:
    probeConfig = renderConfigFile("etc/probe/config.toml",
      "issuer = http://localhost:8080\n")

  service api:
    executable probeBin
    args "--config", probeConfig.path
    identity stable "com.example.l4probe.api"
    scope workspace

  service sidecar:
    executable probeBin
    identity derived
    scope project
"""

proc editedSource(needle, replacement: string): string =
  ## One-line edit to ``WellFormed``. Raises rather than returning a
  ## misleading result when the needle is not present, so a drifted
  ## fixture is a red test and not a silently vacuous one.
  if not WellFormed.contains(needle):
    raise newException(ValueError,
      "fixture drift: WellFormed no longer contains " & needle)
  result = WellFormed.replace(needle, replacement)
  doAssert result != WellFormed

proc edited(needle, replacement, tag: string): ServiceCompileProbeResult =
  checkRecipeSource(editedSource(needle, replacement), tag)

const IdentityLine = "    identity stable \"com.example.l4probe.api\""
const ScopeLine = "    scope workspace"

suite "L4 — the recipe both setters are specified for compiles":

  test "the positive control: both modes and two scopes together":
    # The control for EVERY refusal below. If this goes red the refusals
    # stop being evidence about the thing they name.
    #
    # It is also deliberately BASE-EXPRESSIBLE: this exact source
    # compiles at the base commit too (where both setters are silently
    # dropped), which is what makes the refusals' exit-code movement
    # below a measurement of the refusal rather than of a broken fixture.
    let probe = checkRecipeSource(WellFormed, "l4-wellformed")
    checkpoint(probe.output)
    check probe.ok

suite "L4 — `identity` refuses every spelling it cannot honour":

  test "`identity stable` without an id is refused, and says why":
    let probe = edited(IdentityLine, "    identity stable",
      "l4-stable-no-id")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`identity stable` needs the identifier")
    check probe.mentions("it survives redefinition")

  test "`identity derived \"<id>\"` is refused: there is nothing it means":
    let probe = edited(IdentityLine,
      "    identity derived \"com.example.l4probe.api\"",
      "l4-derived-with-id")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`identity derived` takes no identifier")
    check probe.mentions("digest of the service's materialised definition")

  test "an unrecognised mode is refused, naming the two that exist":
    let probe = edited(IdentityLine, "    identity sticky",
      "l4-unknown-mode")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not recognise the identity mode")
    check probe.mentions("`identity derived`")
    check probe.mentions("`identity stable \"<id>\"`")
    # The author's rule travels with the refusal: knowing the two
    # spellings is not knowing which to pick.
    check probe.mentions("if and only if it owns")

  test "a NON-LITERAL id is refused, because a literal is the guarantee":
    # `identity stable getCurrentDir()` type-checks as Nim and is exactly
    # what §4.2 forbids ("not derived from a path"). The failure it would
    # cause is invisible: the service is simply not the same instance in
    # the next worktree.
    let probe = edited(IdentityLine,
      "    identity stable getCurrentDir()", "l4-computed-id")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("needs a STRING LITERAL identifier")
    check probe.mentions("is not derived from a path")

  test "an EMPTY id is refused":
    let probe = edited(IdentityLine, "    identity stable \"\"",
      "l4-empty-id")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("declares an EMPTY identifier")

  test "a quoted MODE is refused, and the message separates the two":
    let probe = edited(IdentityLine, "    identity \"derived\"",
      "l4-quoted-mode")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("takes a MODE, not a string")

  test "an extra argument beside the mode is refused":
    let probe = edited(IdentityLine,
      "    identity stable \"a\", \"b\"", "l4-identity-extra")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`identity` takes exactly one mode")

  test "a SECOND `identity` declaration is refused, not last-wins":
    let probe = edited(IdentityLine,
      IdentityLine & "\n    identity derived", "l4-identity-twice")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a SECOND `identity` declaration")
    check probe.mentions("depend on statement order")

suite "L4 — `scope` refuses every spelling it cannot honour":

  test "an unrecognised scope is refused, naming the four that exist":
    let probe = edited(ScopeLine, "    scope machine", "l4-unknown-scope")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not recognise the scope")
    for word in ["project", "workspace", "user", "system"]:
      check probe.mentions("`" & word & "`")

  test "a quoted scope is refused":
    let probe = edited(ScopeLine, "    scope \"user\"", "l4-quoted-scope")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("not a string")

  test "two scopes in one statement are refused":
    let probe = edited(ScopeLine, "    scope user, system",
      "l4-scope-two-args")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`scope` takes exactly one value")

  test "a SECOND `scope` declaration is refused":
    let probe = edited(ScopeLine, ScopeLine & "\n    scope user",
      "l4-scope-twice")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is a SECOND `scope` declaration")

suite "L4 — the shapes the setter walk used to SKIP are refused":
  ## THE STANDING HUNT. ``m5ParseServiceBody`` continues past any
  ## statement that is not an ``nnkCall``/``nnkCommand`` with two or more
  ## children, so a bare ident and an assignment form reached no setter
  ## at all. Both are shapes an author arrives at naturally, both
  ## compiled clean at the base commit, and both left the service on the
  ## DEFAULT identity -- which §4.2 says forks a developer's database.

  test "a bare `identity` is refused":
    let probe = edited(IdentityLine, "    identity", "l4-bare-identity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `identity` is written in")
    check probe.mentions("would otherwise SKIP it")

  test "a bare `scope` is refused":
    let probe = edited(ScopeLine, "    scope", "l4-bare-scope")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `scope` is written in")

  test "`identity = derived` is refused":
    let probe = edited(IdentityLine, "    identity = derived",
      "l4-identity-asgn")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `identity` is written in")

  test "`scope = user` is refused":
    let probe = edited(ScopeLine, "    scope = user", "l4-scope-asgn")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `scope` is written in")

  test "`identity()` with no argument is refused":
    let probe = edited(IdentityLine, "    identity()",
      "l4-identity-call-empty")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `identity` is written in")

suite "L4 — the call form and the activity body are the same surface":

  test "`identity(stable(\"<id>\"))` is accepted, like every setter":
    let probe = edited(IdentityLine,
      "    identity(stable(\"com.example.l4probe.api\"))",
      "l4-identity-call-form")
    checkpoint(probe.output)
    check probe.ok

  test "`scope(project)` is accepted, like every setter":
    let probe = edited(ScopeLine, "    scope(project)", "l4-scope-call-form")
    checkpoint(probe.output)
    check probe.ok

  test "`identity` INSIDE an `on <trigger>:` body is refused":
    # The remaining place the two words could be written and reach a
    # different walker. `m5ServiceTriggerActionCall` claims every
    # statement in a trigger body as an action, so this lands on its
    # unknown-action refusal rather than on L4's -- which is right (it IS
    # not an action) and worth pinning, because the alternative a reader
    # might assume is that it silently sets the service's identity.
    const InTrigger = """
import repro_project_dsl

package l4trigRecipe:
  executable trigBin:
    build:
      output("bin/trig")

  service api:
    executable trigBin
    on crash:
      identity stable "com.example.wrong-place"
"""
    let probe = checkRecipeSource(InTrigger, "l4-identity-in-trigger")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not recognise the trigger action")

  test "both setters work inside a dev-env `activity` body":
    # L2 routes a service declared inside an activity through the SAME
    # `m5ServiceEmission`, so this must hold without a second code path.
    # It is asserted rather than assumed: a second walker is exactly the
    # drift that emitter's doc comment was written to prevent.
    const InActivity = """
import repro_project_dsl

package l4actRecipe:
  executable actBin:
    build:
      output("bin/act")

  devEnv:
    activity stack():
      service sso:
        executable actBin
        identity stable "com.example.l4probe.sso"
        scope workspace
"""
    let probe = checkRecipeSource(InActivity, "l4-in-activity")
    checkpoint(probe.output)
    check probe.ok

  test "and a refusal inside an activity body carries the same message":
    const BadInActivity = """
import repro_project_dsl

package l4actBadRecipe:
  executable actBin:
    build:
      output("bin/act")

  devEnv:
    activity stack():
      service sso:
        executable actBin
        identity stable
"""
    let probe = checkRecipeSource(BadInActivity, "l4-in-activity-bad")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`identity stable` needs the identifier")

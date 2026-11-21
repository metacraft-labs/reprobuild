## Shared-Development-Services L6 — the ``compatibility <major>`` setter of
## a ``service`` block: the MAJOR COMPATIBILITY FIELD §4.3's third outcome
## is decided on, every spelling it cannot honour REFUSED rather than
## dropped, and the DOTTED spelling of all three instance-declaration
## setters closed.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real ``nim`` this
## repo is built with and asserts on its real output. See
## ``service_block_compile_probe.nim`` for why the in-process ``check not
## compiles(...)`` spelling cannot be used for a ``package`` block
## (measured: it answers *false* for every one, well-formed or not, so a
## refusal and its control would both be vacuous).
##
## WHICH DISCRIMINATOR EACH CASE RESTS ON, decided rather than assumed.
## At the base commit ``compatibility`` is not a setter at all, so
## ``m5ParseServiceBody``'s closing ``else: discard`` swallows every
## spelling below — the well-formed one AND the malformed ones — and each
## compiles with EXIT 0. So for every refusal here the EXIT STATUS
## genuinely discriminates (0 before, non-zero after) and it is asserted.
## The DIAGNOSTIC TEXT is asserted beside it, because "the build stops" is
## not the requirement: an author who wrote ``compatibility 0`` has to be
## told that 0 is the undeclared value and that declaring it would be
## unobservable.
##
## THE TWO DOTTED CASES ARE DIFFERENT, AND SO IS THEIR EVIDENCE. The
## dotted head is the open escalation on
## ``issues/2026-10-08-service-body-setters-are-silently-dropped.md``:
## ``identity.stable "x"`` and ``scope.workspace`` compile with ZERO
## errors at the base and leave the service on the DEFAULT identity. This
## milestone closes it for the three instance-declaration setters only —
## the ones §4 owns — and the issue's general case (``description.x``,
## ``totallyMadeUp = 3``) stays open, because what a blanket refusing
## ``else`` arm should say about a statement recognised at a different
## level is the judgement that issue was filed to defer.
##
## Governing spec text — ``Shared-Development-Services.md``:
##
## * §4.3's table: "| major compatibility field differs | **Refuse.**
##   Attaching would hand the consumer a handle whose members it cannot
##   use; a warning there would be a defect report written after the
##   damage |"
## * §10: "an incompatible major refuses, and ``--replace`` refuses again
##   while another holder has a live lease".
##
## Every refusal is a one-line edit to ONE well-formed recipe, and that
## recipe's own compile is the first test in the file. The two guards L1's
## sibling files earned are kept: each case asserts the edit actually
## changed the source, and each refusal asserts on the message.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

package l6probeRecipe:
  executable probeBin:
    build:
      output("bin/probe")

  service api:
    executable probeBin
    args "--serve"
    identity stable "com.example.l6probe.api"
    scope workspace
    compatibility 2

  service sidecar:
    executable probeBin
    compatibility 1
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

const CompatLine = "    compatibility 2"
const IdentityLine = "    identity stable \"com.example.l6probe.api\""
const ScopeLine = "    scope workspace"

suite "L6 — the recipe the setter is specified for compiles":

  test "the positive control: a declared major on two services":
    # The control for EVERY refusal below. If this goes red the refusals
    # stop being evidence about the thing they name.
    #
    # It is also deliberately BASE-EXPRESSIBLE: this exact source
    # compiles at the base commit too (where `compatibility` is silently
    # dropped), which is what makes the refusals' exit-code movement
    # below a measurement of the refusal rather than of a broken fixture.
    let probe = checkRecipeSource(WellFormed, "l6-wellformed")
    checkpoint(probe.output)
    check probe.ok

  test "the head name is matched under `normalize`, on both sides":
    # The asymmetry check this campaign's standing hunt demands: L5's
    # blocking defect was a guard comparing the author's spelling
    # VERBATIM while the reading beside it normalised BOTH sides. The
    # literal `"compatibility"` is already in normal form, so the only
    # way this can be wrong is the author's side — hence two spellings
    # that `normalize` folds onto it, which must be ACCEPTED, and a
    # near-miss that it does not, which is refused in its own case below.
    let upper = edited(CompatLine, "    Compatibility 2", "l6-case")
    checkpoint(upper.output)
    check upper.ok
    let underscored = edited(CompatLine, "    compat_ibility 2",
      "l6-underscore")
    checkpoint(underscored.output)
    check underscored.ok

suite "L6 — `compatibility` refuses every spelling it cannot honour":

  test "`compatibility 0` is refused: 0 is the undeclared value":
    let probe = edited(CompatLine, "    compatibility 0", "l6-zero")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`compatibility 0`")
    check probe.mentions("indistinguishable from not declaring")

  test "a negative major is refused":
    let probe = edited(CompatLine, "    compatibility -1", "l6-negative")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("whole number greater than zero")

  test "a quoted major is refused, and says to unquote it":
    let probe = edited(CompatLine, "    compatibility \"2\"", "l6-string")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("not a string")
    check probe.mentions("compatibility 2")

  test "a non-literal major is refused: it must not be computable":
    let probe = edited(CompatLine, "    compatibility someMajor",
      "l6-ident")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("INTEGER LITERAL")

  test "an arithmetic expression is refused for the same reason":
    let probe = edited(CompatLine, "    compatibility 1 + 1", "l6-expr")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("INTEGER LITERAL")

  test "two arguments are refused, with the count":
    let probe = edited(CompatLine, "    compatibility 2, 3", "l6-arity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("takes exactly one major")
    check probe.mentions("2 argument(s)")

  test "the LARGEST major the field holds is ACCEPTED":
    # A literal above `int32` range parses as `nnkInt64Lit`, which the
    # first draft of this setter refused. Probe-sweep finding; the
    # end-to-end half is in
    # `t_l6_compatibility_major_crosses_the_lift.nim`.
    let probe = edited(CompatLine, "    compatibility 4294967295",
      "l6-u32-max")
    checkpoint(probe.output)
    check probe.ok

  test "one more than that does NOT fit, and the refusal says so":
    let probe = edited(CompatLine, "    compatibility 4294967296",
      "l6-over-u32")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not fit the field")
    check probe.mentions("4294967295")

  test "the field's own unsigned spelling is accepted":
    let probe = edited(CompatLine, "    compatibility 2'u32", "l6-u32-suffix")
    checkpoint(probe.output)
    check probe.ok

  test "a SECOND `compatibility` declaration is refused, not last-wins":
    let probe = edited(CompatLine,
      "    compatibility 2\n    compatibility 3", "l6-second")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("already declares its major compatibility")
    check probe.mentions("Delete one")

suite "L6 — the shapes this walker would otherwise SKIP ENTIRELY":

  test "a bare `compatibility` is refused rather than dropped":
    let probe = edited(CompatLine, "    compatibility", "l6-bare")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `compatibility` is written in")

  test "the assignment form is refused rather than dropped":
    let probe = edited(CompatLine, "    compatibility = 2", "l6-asgn")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `compatibility` is written in")

  test "the DOTTED form is refused rather than dropped":
    let probe = edited(CompatLine, "    compatibility.major 2", "l6-dotted")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `compatibility` is written in")

  test "a near-miss NAME is refused, naming the spelling that works":
    # `compatibilityMajor` normalises to `compatibilitymajor`, which is
    # NOT `compatibility`, so the head matcher does not see it and the
    # setter walk's `else: discard` would drop it in silence -- the
    # filed defect's family, on a surface this milestone adds. Caught
    # before it shipped rather than after.
    let probe = edited(CompatLine, "    compatibilityMajor 2",
      "l6-nearmiss-long")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("did you mean `compatibility")

  test "a bare `major` is refused the same way":
    let probe = edited(CompatLine, "    major 2", "l6-nearmiss-major")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("did you mean `compatibility")

suite "L6 — the dotted spelling of L4's two setters, closed here":

  test "`identity.stable \"<id>\"` no longer compiles to the default":
    # The escalation recorded on
    # `issues/2026-10-08-service-body-setters-are-silently-dropped.md`:
    # measured at the base, this compiles with ZERO errors and the
    # service lowers `kind=sikDerived id='' scope=sscProject`.
    let probe = edited(IdentityLine,
      "    identity.stable \"com.example.l6probe.api\"", "l6-dotted-identity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `identity` is written in")

  test "`scope.workspace` no longer compiles to the default":
    let probe = edited(ScopeLine, "    scope.workspace",
      "l6-dotted-scope")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape `scope` is written in")

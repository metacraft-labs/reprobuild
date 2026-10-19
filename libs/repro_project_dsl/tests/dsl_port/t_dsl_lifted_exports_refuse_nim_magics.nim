## Shared-Development-Services L3 — an export cannot be given the name of
## a Nim MAGIC that the lift's accessor would shadow, and the refusal
## lands on the author's own declaration.
##
## WHY THIS SUITE EXISTS. L3's lift emits one top-level
## `proc <exportName>*(pkg: <Title>Package)` per export, so an export
## named after a magic puts that accessor in front of `system`'s routine
## for the WHOLE module. Found in practice: an L4 fixture named its
## service `declared`, the emitted `proc declared*` shadowed
## `system.declared`, and `unittest`'s `check` — which expands to
## `declared(...)` — then failed to compile with
## `cannot generate code for: mDeclared` in EVERY case in the file.
## Reported as `reprobuild-pm/issues/2026-10-09-lift-does-not-reserve-
## nim-magics-so-an-export-breaks-unittest.md` and fixed here.
##
## THE RULE UNDER TEST IS DERIVED FROM THE COMPILER, NOT HAND-KEPT, AND
## THAT IS THE POINT. The issue filed itself rather than fixing itself
## because it believed the check "needs a hand-kept list" that "will be
## wrong the first time someone hits one that is not on it". It does not:
## `getImpl` on a magic symbol returns its `ProcDef` with the
## `magic: "…"` pragma intact, so `l3MagicWithUntypedParam` reserves
## exactly the names `system` declares as a magic AND with an `untyped`
## parameter. Measured in nim 2.3.1 that is eight names — `compiles`,
## `declared`, `declaredInScope`, `defined`, `iterToProc`, `procCall`,
## `runnableExamples`, `typeof` — a superset of the five that were
## measured to actually break. Four cases below pin members of the set
## and one pins the complement, so neither half can drift.
##
## A SIXTH NAME IS REFUSED BY A SECOND, SEPARATE BRANCH of the same
## guard: `nimvm`, which `system` declares as a compiler-context symbol
## no expression may name as a value. It is not a routine, so the magic
## rule above says nothing about it, and the guard cannot even inspect
## it — reaching `liftedMagicShadowRefusal`'s `typed` parameter with
## `system.nimvm` fails the compilation outright with
## `illegal context for 'nimvm' magic`. The guard therefore probes with
## `when compiles(liftedMagicShadowProbe(system.<name>))` first and
## refuses through `liftedCompilerContextShadowRefusal` when that is
## false. The last case below is the regression test for that, and its
## discriminator is the ABSENCE of the compiler-internal line.
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
## EVERY CASE. Measured at `a567a3e1` — the commit this fix is written
## on — with the reservation absent, on the fixtures below:
##
## * `service declared:`, `service compiles:`, `service defined:`,
##   `service declaredInScope:`, `service typeof:` and
##   `activity declared(host: string):` — every one **exit 0**. They
##   COMPILED: the accessor is a perfectly good proc, and nothing in the
##   recipe used the magic afterwards. So `not probe.ok` IS the
##   discriminator for those, and it is checked first in each.
## * the ISSUE'S OWN SHAPE — `service declared:` in a module that also
##   uses `unittest`'s `check` — exit 1, but with
##   `…/lib/pure/unittest.nim(1290, 20) Error: cannot generate code for:
##   mDeclared`: anchored in the STDLIB, naming neither the export, nor
##   the magic, nor any line the author wrote. There `not probe.ok` is
##   vacuous and what discriminates is WHICH diagnostic comes out.
##
##   That case asserts the absence of the stdlib-anchored line rather
##   than the absence of the phrase `cannot generate code for: mDeclared`
##   itself, for a reason worth stating: our own refusal QUOTES that
##   phrase, to tell the author what they would otherwise have seen. So
##   the phrase is still in the output and asserting it gone would fail
##   for the wrong reason; `noStdlibAnchoredError` is the same assertion
##   made precisely. Measured after the fix: no `Error:` line of the
##   output is anchored in any `.nim` file other than the recipe.
## * the SCOPE CONTROL — an activity-nested `service declared:` and a
##   `config:` key named after a magic: exit 0 before and exit 0 after.
##   Those become FIELDS of the lifted handle type, never module-scope
##   procs, so they shadow nothing and the guard must not reach them.
##   `probe.ok` is the discriminator, and it is what goes red if the
##   guard is ever widened to `act.services` or `act.config`.
## * the NEGATIVE CONTROL (`add`, `len`, `default`, `new`) — exit 0
##   before and exit 0 after. These are names the same reflection
##   reports as magics but WITHOUT an untyped parameter, so the rule must
##   leave them alone; measured across all 81 identifier-named magic
##   routines a source scrape of nim 2.3.1's `lib/system.nim` and
##   `lib/system/*.nim` yields, shadowing each, only five break and all
##   five have an untyped parameter. This case is the whole difference
##   between the derived rule and "refuse every magic", which would
##   refuse these four plausible export names.
## * the OTHER CONTROL (`assert`, `doAssert`) — exit 0 before and after.
##   These are the mirror image: an `untyped` first parameter and NO
##   `magic:` pragma. They are the only thing in this file that goes red
##   when the `magic:` half of the conjunction is dropped, because the
##   `add`/`len`/`default`/`new` control has no `untyped` parameter to
##   trip over.
## * the QUALIFICATION CONTROL (`service getAst:` in a recipe that
##   imports `std/macros`) — exit 0 before and after. `std/macros`
##   declares `getAst` as a magic with an `untyped` parameter, and it is
##   NOT `system`'s, so the `system.`-qualified guard must not fire. It
##   is the only case in this file that notices the qualification being
##   dropped.
## * `service nimvm:` — exit 0 before, and with the reservation present
##   but WITHOUT its inner `when compiles(…)` probe it stopped with
##   `Error: illegal context for 'nimvm' magic`. So that case has two
##   discriminators: `not probe.ok` against the before-state and the
##   absence of the compiler-internal line against the probe-less
##   version.
##
## NO REFUSAL CASE ASSERTS ONLY THE EXIT CODE. Each asserts the
## refusal's DIAGNOSTIC TEXT and the anchor: the reported line is the
## line of the author's own declaration in the recipe, computed from the
## fixture rather than written down. The five CONTROL cases assert the
## converse — exit 0, which is the whole claim for a name that must stay
## legal — plus the absence of the refusal's own phrase, so a refusal
## downgraded from an `error` to a `warning` could not pass them.
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

package l3magic:
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

const IssueShape = """
import std/unittest

import repro_project_dsl

package l3magic:
  defaultToolProvisioning "path"

  service declared:
    args "--standalone"

suite "the author's own suite":
  test "the author's own case":
    check 1 + 1 == 2
"""

const ThirdPartyMagic = """
import std/macros

import repro_project_dsl

package l3magic:
  defaultToolProvisioning "path"

  service getAst:
    args "--standalone"
"""

proc editedProducer(needle, replacement: string): string =
  ## One-line edit to `Producer`. Raises rather than returning a
  ## misleading result when the needle is absent, so a drifted fixture is
  ## a red test and not a silently vacuous one.
  if not Producer.contains(needle):
    raise newException(ValueError,
      "fixture drift: Producer no longer contains " & needle)
  result = Producer.replace(needle, replacement)
  doAssert result != Producer

proc editedTwice(needleA, replacementA, needleB, replacementB: string):
    string =
  ## Two one-line edits to `Producer`, each guarded against fixture
  ## drift the same way `editedProducer` guards its one.
  result = editedProducer(needleA, replacementA)
  if not result.contains(needleB):
    raise newException(ValueError,
      "fixture drift: Producer no longer contains " & needleB)
  let once = result
  result = result.replace(needleB, replacementB)
  doAssert result != once

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

proc noStdlibAnchoredError(probe: ServiceCompileProbeResult): bool =
  ## True when NO `Error:` line of the output is anchored in a file
  ## other than the recipe the probe wrote.
  ##
  ## This is the defect's signature stated precisely: the before-state of
  ## the issue's own shape is an `Error:` on a line of
  ## `lib/pure/unittest.nim`, which is no line the author wrote. The
  ## refusal's own message quotes the phrase
  ## `cannot generate code for: mDeclared` on purpose, so the phrase
  ## cannot be used as the discriminator — the ANCHOR can.
  for outLine in probe.output.splitLines():
    if not outLine.contains("Error:"):
      continue
    if not outLine.contains("recipe.nim("):
      return false
  true

suite "L3 — the lift reserves shadowable magics: the controls":

  test "the positive control: legal export names compile":
    # Without this, a reservation that refused EVERY name would satisfy
    # every refusal case below.
    let probe = checkRecipeSource(Producer, "l3-magic-control")
    checkpoint(probe.output)
    check probe.ok
    check not probe.mentions("is RESERVED")

  test "the negative control: magics WITHOUT an untyped parameter stay legal":
    # THIS CASE IS THE DIFFERENCE between the derived rule and "refuse
    # every magic". `add` (AppendStrStr, AppendSeqElem, …), `len`
    # (LengthSeq, LengthStr, …), `default` (Default) and `new` (New,
    # NewFinalize) are all reported as magics by the same `getImpl`
    # reflection the reservation uses, and none of them declares an
    # `untyped` parameter. Each was measured exit 0 as a service name at
    # `a567a3e1`, and shadowing each was measured not to break the
    # magic, so refusing them would refuse four plausible export names
    # for nothing.
    for legal in ["add", "len", "default", "new"]:
      let r = probeFor("service standalone:", "service " & legal & ":",
        "l3-magic-legal-" & legal)
      checkpoint(legal & ": " & r.probe.output)
      check r.probe.ok
      # Not only the exit code: a refusal downgraded to a `warning`
      # would still leave `probe.ok` true.
      check not r.probe.mentions("is RESERVED")

  test "the other control: an `untyped` parameter WITHOUT a magic stays legal":
    # THE RULE IS A CONJUNCTION, and this case is the half the negative
    # control above cannot reach. `system.assert` and `system.doAssert`
    # are templates whose first parameter is `untyped` and which carry NO
    # `magic:` pragma — measured: `system.assert`'s `getImpl().pragma` is
    # empty and its params are `(cond: untyped; msg = "")`. Shadowing
    # them is legal, so the rule must require BOTH conditions.
    #
    # Drop the `magic:` half of `l3MagicWithUntypedParam` and this case
    # goes red while every refusal case below still passes, because each
    # of those names satisfies both halves. The `add`/`len`/`default`/
    # `new` control cannot catch that mutation: none of those four has an
    # `untyped` parameter at all.
    for legal in ["assert", "doAssert"]:
      let r = probeFor("service standalone:", "service " & legal & ":",
        "l3-magic-untypednomagic-" & legal)
      checkpoint(legal & ": " & r.probe.output)
      check r.probe.ok
      check not r.probe.mentions("is RESERVED")

  test "the qualification control: a THIRD-PARTY module's magic is not `system`'s":
    # THE GUARD IS `system.`-QUALIFIED, and this case is what makes that
    # a tested decision rather than a comment. `std/macros` declares
    # `proc getAst*(macroOrTemplate: untyped): NimNode
    # {.magic: "ExpandToAst", noSideEffect.}` — a magic WITH an untyped
    # parameter, outside `system`. The hazard domain the reservation
    # claims is exactly the names `system` itself declares, so a recipe
    # that imports `std/macros` and exports `getAst` must compile:
    # measured exit 0.
    #
    # Replace the emitted `when declared(system.<name>)` with a bare
    # `when declared(<name>)` and this case goes red — and red for the
    # right reason, because the refusal it then produces claims
    # "`system` declares it as the MAGIC `ExpandToAst`", which is false.
    # Nothing else in this file notices that substitution: the fixture
    # the other cases edit declares no symbol of its own and imports
    # nothing but the DSL, so qualified and unqualified agree on every
    # name they try.
    let probe = checkRecipeSource(ThirdPartyMagic, "l3-magic-thirdparty")
    checkpoint(probe.output)
    check probe.ok
    check not probe.mentions("is RESERVED")

  test "the scope control: a magic name that becomes a FIELD stays legal":
    # THIS CASE IS WHAT STOPS THE GUARD FROM BEING WIDENED to names that
    # shadow nothing. `l3MagicShadowGuards` guards exactly the names the
    # lift emits as module-scope `proc`s — `l3Exportable` activities and
    # PACKAGE-LEVEL services. An activity-NESTED service and a `config:`
    # key become FIELDS of the lifted handle object
    # (`L3magicPackageSsoHandle`), and a field named `declared` shadows
    # nothing at all: no accessor `proc` of that name is emitted, so
    # `system.declared` is still the only `declared` in the module.
    # Measured at `a567a3e1` AND after the fix: each of these two edits
    # compiles exit 0. Widen the guard to collect `act.services` or
    # `act.config` and this case goes red while every refusal case above
    # still passes.
    #
    # THE TWO ARE GIVEN DIFFERENT MAGIC NAMES ON PURPOSE. A nested
    # service and a `config:` key of ONE activity that shared a name
    # would be the same member of that one handle type, which
    # `l3CheckExportNames` already refuses by name ("would be the same
    # member of the lifted handle type") — measured, so a fixture naming
    # both `declared` would go red on that pre-existing and correct
    # refusal and would say nothing about this one. `compiles` is the
    # second untyped-parameter magic, so both halves of this case are
    # still names the module-scope rule WOULD refuse.
    let source = editedTwice("service zitadel:", "service declared:",
      "        port: int = 8080", "        compiles: int = 8080")
    let probe = checkRecipeSource(source, "l3-magic-field-scope")
    checkpoint(probe.output)
    check probe.ok
    # Belt and braces: if a widened guard ever fired here, it would
    # error rather than merely warn, so `probe.ok` is the discriminator —
    # but assert the refusal's own phrase is absent too, so a future
    # refusal downgraded to a `warning` could not pass unnoticed.
    check not probe.mentions("is RESERVED")

suite "L3 — an export named after an untyped-parameter magic is refused":

  test "a package-level service named `declared` is refused":
    # `not probe.ok` is LOAD-BEARING here: at `a567a3e1` this exact
    # recipe compiled exit 0, so the refusal is the whole of the
    # change in behaviour.
    let r = probeFor("service standalone:", "service declared:",
      "l3-magic-svc-declared")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("`service declared`")
    check r.probe.mentions("is RESERVED")
    # The magic, named by its MAGIC name and not by the spelling the
    # author typed.
    check r.probe.mentions("the MAGIC `Declared`")
    # Why the accessor is the problem, and what the author would get.
    check r.probe.mentions("shadows `system.declared` for the WHOLE module")
    check r.probe.mentions("intercept the call BY NAME")
    check r.probe.mentions("cannot generate code for: mDeclared")
    check r.probe.mentions("nor any line the author wrote")
    check r.probe.mentions("Rename the service.")
    # Anchored on the author's own `service` head, not on generated code
    # and not in the stdlib.
    check anchoredAt(r.probe, r.line)

  test "an activity named `declared` is refused":
    let r = probeFor("activity sso(host: string):",
      "activity declared(host: string):", "l3-magic-act-declared")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("`activity declared`")
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("the MAGIC `Declared`")
    check r.probe.mentions("Rename the activity.")
    check anchoredAt(r.probe, r.line)

  test "`compiles`, `defined`, `declaredInScope`: each names its own magic":
    # So the rule is a derivation over `system` and not one hard-coded
    # name. Each of these was measured exit 0 as a service name at
    # `a567a3e1`.
    for (name, magic) in [("compiles", "Compiles"), ("defined", "Defined"),
                          ("declaredInScope", "DeclaredInScope")]:
      let r = probeFor("service standalone:", "service " & name & ":",
        "l3-magic-svc-" & name.toLowerAscii())
      checkpoint(name & ": " & r.probe.output)
      check not r.probe.ok
      check r.probe.mentions("`service " & name & "`")
      check r.probe.mentions("is RESERVED")
      check r.probe.mentions("the MAGIC `" & magic & "`")
      check r.probe.mentions("cannot generate code for: m" & magic)
      check r.probe.mentions("Rename the service.")
      check anchoredAt(r.probe, r.line)

  test "`typeof` is reserved by the derivation, not by having broken":
    # PINNED DELIBERATELY. `system.typeof` carries `magic: "TypeOf"` and
    # an `untyped` parameter, so the derived rule reserves it; shadowing
    # it was measured NOT to break the uses tried, and `service typeof:`
    # was exit 0 at `a567a3e1`. It is reserved anyway because the value
    # of this rule is that it is READ OFF THE COMPILER rather than
    # trimmed by hand — a future nim that adds an untyped-parameter
    # magic is then covered without an edit to `macros_b.nim`, and
    # `typeof` is not a plausible export name. Trimming the rule to the
    # measured breakers is what this case forbids.
    let r = probeFor("service standalone:", "service typeof:",
      "l3-magic-svc-typeof")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("`service typeof`")
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("the MAGIC `TypeOf`")
    check anchoredAt(r.probe, r.line)

  test "`nimvm`: the guard's own probe refuses it instead of breaking":
    # THE GUARD MUST NOT ITSELF EMIT A DIAGNOSTIC THE AUTHOR CANNOT ACT
    # ON, and this is the one name in `system` where it nearly did.
    # `liftedMagicShadowRefusal` takes the shadowed symbol through a
    # `typed` parameter, so reaching it SEMS `system.<name>`. Measured
    # over all 632 exported names a source scrape of nim 2.3.1's
    # `lib/system.nim` and `lib/system/*.nim` yields, that sem succeeds
    # for 631 and fails for exactly one — `nimvm`, declared `let nimvm*
    # {.magic: "Nimvm", compileTime.}: bool`, which the compiler accepts
    # only as a `when` condition. Without the inner
    # `when compiles(liftedMagicShadowProbe(system.<name>))` the recipe
    # below stopped with `Error: illegal context for 'nimvm' magic`,
    # naming neither the export nor anything the author wrote: the exact
    # failure mode this whole reservation exists to end, reintroduced by
    # the reservation.
    #
    # `nimvm` is refused rather than waved through because shadowing it
    # is a real hazard: a module-scope `proc nimvm*` beside it was
    # measured to make `when nimvm:` report
    # `ambiguous identifier: 'nimvm'`. At `a567a3e1` this recipe was
    # exit 0, so `not probe.ok` is load-bearing here too.
    let r = probeFor("service standalone:", "service nimvm:",
      "l3-magic-svc-nimvm")
    checkpoint(r.probe.output)
    check not r.probe.ok
    check r.probe.mentions("`service nimvm`")
    check r.probe.mentions("is RESERVED")
    check r.probe.mentions("COMPILER-CONTEXT symbol")
    check r.probe.mentions("ambiguous identifier: 'nimvm'")
    check r.probe.mentions("Rename the service.")
    check anchoredAt(r.probe, r.line)
    # THE DISCRIMINATOR for the probe itself: remove the inner
    # `when compiles(...)` and this is the line that comes back.
    check not r.probe.mentions("illegal context for 'nimvm' magic")
    check noStdlibAnchoredError(r.probe)

suite "L3 — the issue's own shape: `declared` plus `unittest`'s `check`":

  test "the refusal replaces `cannot generate code for: mDeclared` in the stdlib":
    # The reported defect, verbatim: a package exporting `service
    # declared:` in a module that also uses `check`. At `a567a3e1` this
    # fixture failed with
    #   …/lib/pure/unittest.nim(1290, 20) Error: cannot generate code
    #   for: mDeclared
    # — the build stopped, loudly, on a stdlib line, naming nothing the
    # author wrote. After the fix it stops on the author's `service`
    # head instead.
    let probe = checkRecipeSource(IssueShape, "l3-magic-issue-shape")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`service declared`")
    check probe.mentions("is RESERVED")
    check probe.mentions("the MAGIC `Declared`")
    check probe.mentions("Rename the service.")
    check anchoredAt(probe, declarationLine(IssueShape, "service declared:"))
    # The before-state must be GONE: no `Error:` anchored anywhere but
    # the author's own recipe. See `noStdlibAnchoredError` for why the
    # anchor and not the phrase is the discriminator here.
    check noStdlibAnchoredError(probe)
    check not probe.mentions("unittest.nim(1290")

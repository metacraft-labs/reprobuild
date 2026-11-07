## Shared-Development-Services L1 — the ``service <ident>:`` setter surface
## is the one ``Package-Model.md`` specifies, and its boundary is enforced
## by the compiler rather than by a silent drop.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real ``nim`` this repo
## is built with and asserts on its real output. See
## ``service_block_compile_probe.nim`` for why the in-process ``compiles``
## spelling cannot be used here (short version: measured, it answers
## *false* for every ``package`` block — well-formed or not — so both a
## refusal and its control would be vacuous).
##
## Governing spec text — ``Package-Model.md`` §Collections:
##
## * "``service`` does not have a ``config:`` setter. Configuration is the
##   package's job: package-level ``config:`` configurables plus rendering
##   helpers (``literalConfigFile``, ``configFile``, etc.) produce a
##   ``BuildOutput``, and the service consumes that output the same way any
##   other build output is consumed — either by reference on argv or via
##   ``runtimeFile``."
## * "``args "...", "...", ...`` — the variadic command-line arguments, in
##   one statement."
## * "``runtimeFile <buildOutput>`` — declares a build output that the
##   service must have alongside it at runtime even though the path does
##   not appear on argv."
##
## Every refusal is a one-line edit to ONE well-formed recipe, and that
## recipe's own compile is the first test in the file. Two further guards,
## both earned: each case asserts the edit actually changed the source (a
## ``replace`` whose needle has drifted silently returns the input, which
## would turn a refusal test into a second run of the control), and the
## refusals assert on the DIAGNOSTIC rather than only on the exit code —
## the first draft of this file passed its ``runtimeFile`` refusal because
## the fixture it generated had an unterminated string literal, so "it
## failed to compile" was true and said nothing about ``runtimeFile``.
##
## The ``args 42`` case additionally records a behaviour CHANGE: before
## this milestone a non-string-literal argument was silently dropped — the
## setter compiled, produced no diagnostic, and left the argument out.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl
import repro_dsl_stdlib/types

var probeConfig: BuildOutput

package probeRecipe:
  config:
    issuer: string = "http://localhost:8080"

  executable probeBin:
    build:
      output("bin/probe")

  build:
    probeConfig = renderConfigFile("etc/probe/config.toml",
      "issuer = http://localhost:8080\n")

  service api:
    executable probeBin
    args "--config", probeConfig.path
    runtimeFile probeConfig
    on change probeConfig:
      sendSignal "SIGHUP"
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
  ## One-line edit to ``WellFormed``, compiled.
  checkRecipeSource(editedSource(needle, replacement), tag)

proc anchorTag(source, statement: string; column: int): string =
  ## The ``recipe.nim(<line>, <column>)`` prefix Nim prints for the line
  ## of ``source`` whose text is ``statement``.
  ##
  ## Computed from the generated source rather than hard-coded, because a
  ## hard-coded line number turns every unrelated fixture edit into a
  ## failure that says nothing about the anchor. The COLUMN is the thing
  ## under test and stays literal.
  var lineNo = 0
  for line in source.splitLines():
    inc lineNo
    if line.strip() == statement:
      return "recipe.nim(" & $lineNo & ", " & $column & ")"
  raise newException(ValueError,
    "fixture drift: the generated source has no line `" & statement & "`")

suite "L1 — the recipe the setter surface is specified for compiles":

  test "the positive control: every specified setter together":
    # The control for EVERY refusal below. If this goes red the refusals
    # stop being evidence about the thing they name.
    let probe = checkRecipeSource(WellFormed, "wellformed")
    checkpoint(probe.output)
    check probe.ok

suite "L1 — `config:` inside a service body is refused, with a diagnostic":

  test "it does not compile, and the message says where config belongs":
    # "It failed to compile" satisfies "the build stops" and none of the
    # requirement: the author has to be told that configuration is the
    # package's job and which setter carries the rendered output.
    let probe = edited(
      "  service api:\n    executable probeBin",
      "  service api:\n    config:\n" &
        "      issuer: string = \"http://x\"\n    executable probeBin",
      "config-block")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("has no `config:` setter")
    check probe.mentions("renderConfigFile")
    check probe.mentions("runtimeFile")

suite "L1 — args and runtimeFile are typed, not stringly":

  test "`args 42` is a type error rather than a dropped argument":
    let probe = edited(
      "    args \"--config\", probeConfig.path",
      "    args \"--config\", 42",
      "args-int")
    checkpoint(probe.output)
    check not probe.ok
    # The diagnostic has to be about the ARGUMENT, at the service's own
    # line, rather than a cascade from somewhere else in the recipe.
    check probe.mentions("addActiveServiceArg")

  test "`runtimeFile` refuses a bare string — it takes a build output":
    let probe = edited(
      "    runtimeFile probeConfig",
      "    runtimeFile \"etc/probe/config.toml\"",
      "runtimefile-string")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("addActiveServiceRuntimeFile")

  test "`args` accepts the handle itself as well as its `.path`":
    # The control that keeps the two refusals above from being a blanket
    # "args only takes literals": a ``BuildOutput`` handle is accepted.
    let probe = edited(
      "    args \"--config\", probeConfig.path",
      "    args \"--config\", probeConfig",
      "args-handle")
    checkpoint(probe.output)
    check probe.ok

suite "L1 follow-up — an unrecognised trigger or action is refused":
  # The defect this suite pins, measured on `e7546acd2`: an `on <trigger>:`
  # head the walker did not recognise produced NO RECORD AT ALL, and an
  # unrecognised action inside a trigger the walker DID recognise left that
  # trigger with zero actions. Both were silent — no diagnostic, exit 0.
  # Probed on that commit, a service body of `on ready: sendSignal "SIGHUP"`
  # / `on crash: converge relyingParties` / `on stop: exec "..."` recorded
  # `triggers=2`, the `stkCrash` one with `actions=0`, and the identifier
  # `relyingParties` never reached the compiler.
  #
  # That is the SAME defect class L1 removed from `args` (see the
  # `args 42` case above), so it does not get to be reintroduced one setter
  # to the left.
  #
  # WHY `on ready:` IS REFUSED RATHER THAN RECOGNISED. It is the spelling
  # `Shared-Development-Services.md` §9 "Worked example" uses, so the
  # temptation is to accept it. The authority for the IMPLEMENTED surface is
  # `Package-Model.md` §"Service Lifecycle And Reactive Triggers", which
  # enumerates exactly three groups — build-graph (`on rebuild <ident>`),
  # runtime-file (`on change <buildOutput>` / `on change "<path>"`) and
  # lifecycle (`on start` / `on stop` / `on crash`). `ready` is in none of
  # them, and it cannot be: a readiness trigger needs the `readiness` probe
  # that says WHEN a service is ready, which §9 declares one line above the
  # trigger (`readiness httpGet("/debug/ready", port = port)`) and which this
  # release does not implement — and whose edge semantics are still
  # `Shared-Development-Services.md` §8 open decision **D-SS10**. Recognising
  # the head without the probe would record a trigger that can never fire,
  # which is a silent no-op wearing the clothes of support. So the refusal
  # NAMES the gap instead, and the test asserts that it does.

  test "`on ready:` is refused, with its spelling and the recognised set":
    let probe = edited(
      "    on change probeConfig:\n      sendSignal \"SIGHUP\"",
      "    on ready:\n      sendSignal \"SIGHUP\"",
      "on-ready")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not recognise the trigger `on ready:`")
    # The recognised alternatives, so the author does not have to go
    # reading the macro to find out what IS accepted.
    check probe.mentions("on rebuild <ident>")
    check probe.mentions("on change <buildOutput>")
    check probe.mentions("on start")
    check probe.mentions("on stop")
    check probe.mentions("on crash")
    # And the specific reason THIS spelling is refused rather than missing,
    # because it is the one the design's own worked example uses.
    check probe.mentions("Shared-Development-Services.md")
    check probe.mentions("readiness")

  test "an unrecognised action inside a recognised trigger is refused":
    let probe = edited(
      "    on change probeConfig:\n      sendSignal \"SIGHUP\"",
      "    on crash:\n      converge relyingParties",
      "unknown-action")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("does not recognise the trigger action")
    # The offending spelling, verbatim — an error that does not quote it
    # leaves the author grepping a multi-trigger service for the one the
    # compiler meant.
    check probe.mentions("converge relyingParties")
    check probe.mentions("on crash")
    # The recognised action set.
    check probe.mentions("hotReload")
    check probe.mentions("restart")
    check probe.mentions("sendSignal")
    check probe.mentions("exec")
    check probe.mentions("notify")

  test "`on <trigger>` with no block body is refused rather than ignored":
    # `on crash` without the colon is a Command of two children, which the
    # walker's arity guard declined — silently, so a dropped colon turned a
    # crash policy into nothing.
    let probe = edited(
      "    on change probeConfig:\n      sendSignal \"SIGHUP\"",
      "    on crash",
      "on-no-body")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("needs a block body of actions")

  test "`sendSignal` refuses a second argument rather than dropping it":
    # `addActiveServiceTriggerAction` reads one argument, so the walker read
    # `stmt[1]` and ignored the rest.
    let probe = edited(
      "      sendSignal \"SIGHUP\"",
      "      sendSignal \"SIGHUP\", \"SIGTERM\"",
      "sendsignal-arity")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`sendSignal` takes exactly one argument")

  test "the control: every recognised trigger and action still compiles":
    # The control WITHOUT which all four refusals above — and the modifier
    # refusals in the next suite — could be passed by a walker that refuses
    # every `on` block. It exercises each of the SIX trigger spellings
    # `Package-Model.md` recognises (`on rebuild <ident>`, `on change
    # <buildOutput>`, `on change "<path>"`, `on start`, `on stop`,
    # `on crash`), each of the five actions, the supervisor-option form of
    # `restart`, and all three short-form atoms — in one service.
    #
    # The count used to read "five" here while the body below covered six;
    # corrected after the review counted them. A control that miscounts its
    # own coverage invites the next reader to add the "missing" spelling and
    # find it already there.
    let probe = edited(
      "    on change probeConfig:\n      sendSignal \"SIGHUP\"",
      "    on change probeConfig:\n      sendSignal \"SIGHUP\"\n" &
        "    on change \"/var/lib/probe/keys\":\n" &
        "      sendSignal \"SIGUSR1\"\n" &
        "    on start:\n      exec \"scripts/warm.sh\"\n" &
        "    on stop:\n      exec \"scripts/drain.sh\"\n" &
        "    on crash:\n" &
        # A doc comment inside a trigger body is not an action and is not a
        # mistake: `nnkCommentStmt` has to stay exempt, or the refusal above
        # turns documenting a trigger into a compile error.
        "      ## why this policy\n" &
        "      restart backoff = exponential, maxRetries = 3\n" &
        "    on rebuild probeBin:\n      hotReload\n" &
        "      notify \"webhook\"\n" &
        "    hotReload\n    restartOnCrash\n" &
        "    reloadOnChange probeConfig, \"SIGHUP\"",
      "all-triggers")
    checkpoint(probe.output)
    check probe.ok

suite "L1 follow-up — a SPECIFIED but unimplemented modifier says so":
  # The finding this suite pins, measured on `a23bdaf37`: `debounce =
  # "200ms"` and `coalesce` written inside an `on` body were refused — the
  # right direction — but with the diagnostic for an unrecognised ACTION,
  # which calls them "trigger action"s and lists only the five actions. Both
  # are spellings `Package-Model.md` §"Service Lifecycle And Reactive
  # Triggers" sets out verbatim, under "Modifiers attached to an `on:` block
  # coalesce noisy signals". So an author writing the documented spelling
  # was told it is not a thing, rather than that it is specified and not yet
  # built — the same disservice as a silent drop, one step to the left.
  #
  # The refusal stays. Only the message changes, and it changes to the shape
  # `on ready:` already uses: cite the section, say what is MISSING
  # (`ServiceTriggerDef` has no field a modifier could be carried in, and
  # nothing consumes a trigger yet), and name the open decision — the spec
  # says "modifiers attached to an `on:` block" and never fixes WHERE one is
  # written, so the in-body spelling is not established either.
  #
  # Which is why the head position is in this suite too: `on change cfg,
  # debounce = "200ms":` is the spec's sentence read the other way, and on
  # `a23bdaf37` it COMPILED, with the modifier dropped in silence — the walker
  # read `stmt[1]` and `stmt[^1]` and nothing between them.

  test "`debounce = \"200ms\"` names itself specified, not unrecognised":
    const Statement = "debounce = \"200ms\""
    let source = editedSource(
      "      sendSignal \"SIGHUP\"",
      "      " & Statement & "\n      sendSignal \"SIGHUP\"")
    let probe = checkRecipeSource(source, "modifier-debounce")
    checkpoint(probe.output)
    check not probe.ok
    # The class: a MODIFIER the spec contains, not a word the author made up.
    check probe.mentions("`debounce` is a trigger MODIFIER")
    check probe.mentions("does NOT implement")
    check probe.mentions("Modifiers attached to an `on:` block")
    # The spec's own description, so the author can tell whether the
    # feature they wanted is the feature that is missing.
    check probe.mentions("wait for the trigger to stop firing")
    # What is missing, and the open decision — the two things the
    # `on ready:` refusal carries and this one did not.
    check probe.mentions("nowhere to be carried")
    check probe.mentions("never fixes WHERE one is written")
    # And the discriminator: the OLD message, which is what `a23bdaf37`
    # printed for this spelling. Without this check the test passes against
    # the defect it exists to pin.
    check not probe.mentions("does not recognise the trigger action")
    # The anchor (finding 3): the offending statement's own column, 7, not
    # the `=` at column 16 the `nnkAsgn` node carries.
    check probe.mentions(anchorTag(source, Statement, 7))
    check not probe.mentions(anchorTag(source, Statement, 16))

  test "`coalesce` names itself specified, not unrecognised":
    const Statement = "coalesce"
    let source = editedSource(
      "      sendSignal \"SIGHUP\"",
      "      " & Statement & "\n      sendSignal \"SIGHUP\"")
    let probe = checkRecipeSource(source, "modifier-coalesce")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`coalesce` is a trigger MODIFIER")
    check probe.mentions("does NOT implement")
    check probe.mentions("run the body once more afterwards")
    check probe.mentions("nowhere to be carried")
    check probe.mentions("never fixes WHERE one is written")
    check not probe.mentions("does not recognise the trigger action")
    # A bare ident already anchored correctly; asserted so the anchor fix
    # is shown not to have moved it.
    check probe.mentions(anchorTag(source, Statement, 7))

  test "a modifier beside the trigger head is refused, not dropped":
    # On `a23bdaf37` this compiled clean with the modifier recorded nowhere.
    const Statement = "on change probeConfig, debounce = \"200ms\":"
    let source = editedSource(
      "    on change probeConfig:",
      "    " & Statement)
    let probe = checkRecipeSource(source, "modifier-head")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`debounce` is a trigger MODIFIER")
    check probe.mentions("attached to the head of `on change probeConfig:`")
    # The modifier's own column within the head line, 28, rather than the
    # statement's — the author has to be pointed at the token.
    check probe.mentions(anchorTag(source, Statement, 28))

  test "an extra head argument that is NOT a modifier is refused too":
    # The same silent drop with a spelling the spec does not contain, so
    # the head-position guard is not just a `debounce`/`coalesce` lookup.
    const Statement = "on change probeConfig, whatever = 3:"
    let source = editedSource(
      "    on change probeConfig:",
      "    " & Statement)
    let probe = checkRecipeSource(source, "head-extra")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("takes one trigger spec and a block body")
    check probe.mentions("whatever = 3")

  test "an extra argument on the SERVICE head is refused, not dropped":
    # One level up from the trigger head above, and the same read:
    # `m5ServiceEntryAst` accepted any arity of three or more and took
    # only `stmt[1]` (the name) and `stmt[^1]` (the body), so on
    # `8dca63efa` `service api, junkArg:` lowered exactly as
    # `service api:` would and `junkArg` — an identifier that exists
    # nowhere in the recipe — was never semchecked. Filed with its
    # `config`-head sibling as `reprobuild-pm/issues/2026-10-08-activity-
    # config-head-arguments-are-silently-dropped.md`.
    #
    # Asserted on the diagnostic AND on the exit code, and here the exit
    # code is load-bearing: measured, this fixture compiles with zero
    # errors at `8dca63efa`, so `not probe.ok` fails before the change
    # and passes after. The diagnostic assertions pin the refusal to the
    # offending token and message.
    const Statement = "service api, junkArg:"
    let source = editedSource("  service api:", "  " & Statement)
    let probe = checkRecipeSource(source, "service-head-extra")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`service <name>:` takes one name and a block " &
      "body of setters")
    # The offending text verbatim, and the service it was written on.
    check probe.mentions("`junkArg` beside the head of `service api:`")
    # Where the setters go, so the author is told the remedy and not
    # only the refusal.
    check probe.mentions("everything it carries is a setter in the body")
    check probe.mentions("runtimeFile <buildOutput>")
    # The offending token's own column, 16, rather than the statement's 3.
    check probe.mentions(anchorTag(source, Statement, 16))

  test "the string-form name takes the same guard":
    # `service "api", junkArg:` is the same defect with the other
    # spelling of the name, and `m5ServiceNameNode` accepts both — so a
    # guard written against the ident form only would leave half of it
    # open.
    const Statement = "service \"api\", junkArg:"
    let source = editedSource("  service api:", "  " & Statement)
    let probe = checkRecipeSource(source, "service-head-extra-strlit")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`junkArg` beside the head of `service \"api\":`")
    check probe.mentions(anchorTag(source, Statement, 18))

  test "the control: the one-name head still compiles, three ways":
    # WITHOUT this the two refusals above are satisfiable by a guard that
    # refuses every `service` head. It exercises the ident form (the
    # `WellFormed` control at the top of this file already does), the
    # STRING form, and two services in one package — the arity the guard
    # has to keep accepting.
    let probe = edited(
      "  service api:\n    executable probeBin",
      "  service \"renamed-api\":\n    executable probeBin\n" &
        "  service second:\n    executable probeBin\n" &
        "    args \"--second\"\n  service api:\n    executable probeBin",
      "service-head-control")
    checkpoint(probe.output)
    check probe.ok

  test "an unspecified assignment is still an unrecognised ACTION, at col 7":
    # The other half of the class split: a spelling the spec does NOT
    # contain keeps the unrecognised-action message, so the modifier
    # diagnostic cannot be reached by writing any assignment at all. It
    # gains only the anchor fix — column 7, not the `=` at column 21.
    const Statement = "somethingElse = 3"
    let source = editedSource(
      "      sendSignal \"SIGHUP\"",
      "      " & Statement)
    let probe = checkRecipeSource(source, "asgn-action")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions(
      "does not recognise the trigger action `somethingElse = 3`")
    check not probe.mentions("is a trigger MODIFIER")
    check probe.mentions(anchorTag(source, Statement, 7))
    check not probe.mentions(anchorTag(source, Statement, 21))

  test "the control: `hotReload otherwise <action>` still compiles":
    # `Package-Model.md` specifies this spelling in the same section, and it
    # is accepted rather than refused — the reading is that the line is not
    # "is it implemented" (nothing consumes any trigger yet) but "can the
    # record HOLD it": the fallback lands in
    # `ServiceTriggerAction.argument`, exactly where `restart`'s supervisor
    # options land, whereas a modifier has no field at all and would be
    # discarded. `t_dsl_service_typed_edges.nim`'s "`hotReload otherwise
    # <action>` is RECORDED, not merely accepted" is the measurement behind
    # that sentence; this case is only the compile half.
    let probe = edited(
      "    on change probeConfig:\n      sendSignal \"SIGHUP\"",
      "    on rebuild probeBin:\n" &
        "      hotReload otherwise sendSignal \"SIGHUP\"",
      "hotreload-otherwise")
    checkpoint(probe.output)
    check probe.ok

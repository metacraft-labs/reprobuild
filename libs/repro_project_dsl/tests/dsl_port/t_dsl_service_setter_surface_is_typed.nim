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

proc edited(needle, replacement, tag: string): ServiceCompileProbeResult =
  ## One-line edit to ``WellFormed``, compiled. Raises rather than
  ## returning a misleading result when the needle is not present, so a
  ## drifted fixture is a red test and not a silently vacuous one.
  if not WellFormed.contains(needle):
    raise newException(ValueError,
      "fixture drift: WellFormed no longer contains " & needle)
  let source = WellFormed.replace(needle, replacement)
  doAssert source != WellFormed
  checkRecipeSource(source, tag)

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
    # The control WITHOUT which all four refusals above could be passed by a
    # walker that refuses every `on` block. It exercises each of the five
    # trigger spellings `Package-Model.md` recognises, each of the five
    # actions, the supervisor-option form of `restart`, and all three
    # short-form atoms — in one service.
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

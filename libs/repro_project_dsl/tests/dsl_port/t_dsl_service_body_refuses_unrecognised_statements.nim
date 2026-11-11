## A ``service`` body holds its setters and nothing else: every other
## statement is REFUSED with its spelling named, and a spelling the DSL
## recognises somewhere else is told where it belongs.
##
## Governing spec text — ``Package-Model.md``:
##
## * §Collections: "Inside ``service``, the body uses small declarative
##   setters" — and every statement of a ``service`` body is one of them,
##   a doc comment, or a ``discard``.
## * §"Service Lifecycle And Reactive Triggers": trigger actions
##   (``sendSignal``, ``exec``, ``notify``, ``restart``, ``hotReload``)
##   are written "inside an ``on:`` body", and the section's rule is to
##   fail "with a clear error rather than silently dropping it".
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every case compiles a real recipe module with the real ``nim`` this
## repo is built with and asserts on its real output; see
## ``service_block_compile_probe.nim`` for why ``compiles(...)`` cannot
## be used for a ``package`` block.
##
## WHICH DISCRIMINATOR EACH CASE RESTS ON. A walk that skips a statement
## it cannot read as a setter compiles every edited recipe below with
## EXIT 0, except `restart backoff = ...`, which then fails only with a
## type mismatch on a parameter name. So the exit status is asserted,
## and the DIAGNOSTIC TEXT is asserted beside it, because the
## requirement is that the author is told where the statement belongs,
## not merely that the build stops.
##
## Every refusal is a one-line edit to ONE well-formed recipe, whose own
## compile is the first test: if the control goes red, the refusals stop
## being evidence about the statement they name.

import std/[strutils, unittest]

import ./service_block_compile_probe

const WellFormed = """
import repro_project_dsl

package bodyprobeRecipe:
  executable probeBin:
    build:
      output("bin/probe")

  service api:
    ## A doc comment declares nothing and is accepted.
    executable probeBin
    args "--serve"
    description "probe service"
    restart "on-failure"
    on crash:
      restart
    discard
"""

const ArgsLine = "    args \"--serve\""
const DescriptionLine = "    description \"probe service\""
const RestartLine = "    restart \"on-failure\""

proc edited(needle, replacement, tag: string): ServiceCompileProbeResult =
  ## One-line edit to ``WellFormed``. Raises when the needle is absent, so
  ## a drifted fixture is a red test rather than a vacuous one.
  if not WellFormed.contains(needle):
    raise newException(ValueError,
      "fixture drift: WellFormed no longer contains " & needle)
  let source = WellFormed.replace(needle, replacement)
  doAssert source != WellFormed
  checkRecipeSource(source, tag)

proc added(line, tag: string): ServiceCompileProbeResult =
  ## ``line`` added to the ``service`` body after ``args``.
  edited(ArgsLine, ArgsLine & "\n" & line, tag)

suite "service body — the control compiles":

  test "setters, an `on` block, a doc comment and a `discard`":
    let probe = checkRecipeSource(WellFormed, "body-wellformed")
    checkpoint(probe.output)
    check probe.ok

suite "service body — a recognised spelling in the wrong place":

  test "`sendSignal` one level out of its `on` block is a trigger ACTION":
    let probe = added("    sendSignal \"SIGHUP\"", "body-sendsignal")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`sendSignal \"SIGHUP\"` is a trigger ACTION")
    check probe.mentions("inside an `on <trigger>:` block")
    check probe.mentions("reloadOnChange")

  test "`exec` and `notify` at the top level are trigger ACTIONs":
    let execProbe = added("    exec \"scripts/drain.sh\"", "body-exec")
    checkpoint(execProbe.output)
    check not execProbe.ok
    check execProbe.mentions("is a trigger ACTION")
    let notifyProbe = added("    notify \"webhook\"", "body-notify")
    checkpoint(notifyProbe.output)
    check not notifyProbe.ok
    check notifyProbe.mentions("is a trigger ACTION")

  test "a trigger head without its `on` is told to add it":
    let probe = added("    crash:\n      restart", "body-no-on")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("trigger written without its `on`")

  test "a trigger MODIFIER at the top level is specified-but-unimplemented":
    let probe = added("    debounce = \"200ms\"", "body-debounce")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`debounce` is a trigger MODIFIER")
    check probe.mentions("at the top level of a `service` body")

  test "`hotReload otherwise ...` at the top level says where it goes":
    let probe = added("    hotReload otherwise sendSignal \"SIGHUP\"",
      "body-hotreload-otherwise")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape the `service` setter `hotReload`")
    check probe.mentions("belongs inside an `on <trigger>:` block")

  test "`restart backoff = ...` is the ACTION's option, not the policy":
    let probe = edited(RestartLine, "    restart backoff = exponential",
      "body-restart-backoff")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape the `service` setter `restart`")
    check probe.mentions("restartOnCrash")

suite "service body — a setter in a shape the walk cannot read":

  test "a dotted head on a setter is told to write the name bare":
    let probe = edited(DescriptionLine, "    description.x \"whatever\"",
      "body-dotted-description")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("writes the `service` setter `description` " &
      "behind a dotted head")

  test "a bare setter name is told its shape":
    let probe = edited(DescriptionLine, "    description",
      "body-bare-description")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions(
      "is not a shape the `service` setter `description`")
    check probe.mentions("`description \"<text>\"`")

  test "an assigned setter is told its shape":
    let probe = edited(DescriptionLine, "    description = \"probe\"",
      "body-asgn-description")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions(
      "is not a shape the `service` setter `description`")

  test "a single-value setter given two values is refused, not halved":
    let probe = edited(DescriptionLine, "    description \"a\", \"b\"",
      "body-two-descriptions")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions(
      "is not a shape the `service` setter `description`")

  test "`executable` given two values is refused, not halved":
    let probe = edited("    executable probeBin",
      "    executable probeBin, otherBin", "body-two-executables")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions(
      "is not a shape the `service` setter `executable`")

  test "a refused setter shape is not described as skipped":
    # The L4 and L9 near-miss refusals run ahead of the generic one; the
    # walk refuses every statement, so none of them may tell the author
    # that the statement would have been skipped.
    for (spelling, tag) in [("readiness()", "body-l9-empty"),
                            ("readiness", "body-l9-bare"),
                            ("cfg.readiness none", "body-l9-dotted"),
                            ("identity = derived", "body-l4-assigned")]:
      let probe = added("    " & spelling, tag)
      checkpoint(probe.output)
      check not probe.ok
      check probe.mentions(spelling)
      check not probe.output.toLowerAscii.contains("skip")

  test "`env` in the command form is told the call form":
    let probe = added("    env \"KEY\", \"VALUE\"", "body-env-command")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("is not a shape the `service` setter `env`")
    check probe.mentions("`env(\"<KEY>\", \"<VALUE>\")`")

suite "service body — a statement that is nothing at all":

  test "an unknown assignment is refused by name":
    let probe = added("    totallyMadeUp = 3", "body-made-up")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`service` does not recognise `totallyMadeUp = 3`")
    check probe.mentions("`runtimeFile <buildOutput>`")

  test "near-misses of `compatibility` no list enumerates are refused":
    for spelling in ["compatibilityVersion 2", "interfaceCompatibility 2"]:
      let probe = added("    " & spelling,
        "body-near-" & spelling.split(' ')[0])
      checkpoint(probe.output)
      check not probe.ok
      check probe.mentions("`service` does not recognise `" & spelling & "`")

  test "an ordinary Nim statement is refused by name":
    let probe = added("    let port = 8080", "body-let")
    checkpoint(probe.output)
    check not probe.ok
    check probe.mentions("`service` does not recognise `let port = 8080`")

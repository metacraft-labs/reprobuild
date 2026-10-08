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
